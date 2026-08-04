defmodule Shep.AgentRunner do
  @moduledoc "Executes a single task: worktree → prompt → Claude Code → cleanup."

  require Logger

  alias Shep.AgentRunner.Exec
  alias Shep.Workspace

  @doc "Run a task end-to-end. Called inside a Task.Supervisor-spawned process."
  @spec run(Shep.Task.t(), pid(), map()) :: Shep.RunResult.t()
  def run(%Shep.Task{} = task, orchestrator_pid, opts \\ %{}) do
    Logger.metadata(task_id: task.id, task_type: task.type)
    started_at = System.monotonic_time(:millisecond)
    config = opts[:config] || Shep.Config.current!()

    :telemetry.execute([:shep, :agent, :start], %{}, %{task_id: task.id, task_type: task.type})

    case resolve_workspace(task, opts, config) do
      {:ok, workspace, resuming?} ->
        run_in_workspace(workspace, resuming?, task, orchestrator_pid, config, started_at)

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - started_at

        %Shep.RunResult{
          iterations: [],
          completion: %Shep.Completion.Failed{reason: reason, recoverable: true},
          branch_name: task.branch,
          worktree_path: "",
          duration_ms: duration
        }
    end
  end

  defp run_in_workspace(workspace, resuming?, task, orchestrator_pid, config, started_at) do
    where = Workspace.describe(workspace)
    Logger.info("Workspace ready for task #{task.id}: #{where}")

    Logger.info(
      "agent phase: streaming to .shep/runs/#{task.id}.stdout.log; " <>
        "this log stays quiet except gap heartbeats until verify"
    )

    log_model_override(task)
    session = Exec.agent_module(task.agent).session_name(task.id)

    send(orchestrator_pid, {:agent_meta, task.id, %{worktree_path: where, session_name: session}})

    case ready_hook(workspace, config, resuming?) do
      :ok -> execute(workspace, resuming?, task, orchestrator_pid, config, started_at, where)
      {:error, reason} -> hook_failed(workspace, task, config, reason, started_at, where)
    end
  end

  defp ready_hook(_workspace, _config, true), do: :ok

  defp ready_hook(workspace, config, false),
    do: Workspace.run_hook(workspace, config, "on_worktree_ready")

  # A broken `on_worktree_ready` — dead network, OOM install, lost fetch
  # race — leaves a checkout the agent cannot work in. Fail before the
  # first turn instead of briefing an agent into it: no model call has
  # happened yet, so the retry costs nothing, and the failure names the
  # layer that actually broke. Recoverable, because this class is
  # overwhelmingly transient.
  defp hook_failed(workspace, task, config, reason, started_at, where) do
    Logger.error("on_worktree_ready failed for task #{task.id}, not starting the agent: #{reason}")

    final = %Shep.Completion.Failed{
      reason: "on_worktree_ready hook failed: #{reason}",
      recoverable: true
    }

    Workspace.cleanup(workspace, task, final, config)
    finish(task, [], final, nil, where, started_at)
  end

  defp execute(workspace, resuming?, task, orchestrator_pid, config, started_at, where) do
    max_turns = get_in(config, ["agent", "max_turns"]) || 10

    iterations =
      if resuming? do
        execute_resume_turns(workspace, task, orchestrator_pid, max_turns, config)
      else
        prompt = Shep.PromptBuilder.build_expanded(task, Workspace.prompt_cwd(workspace, config))

        execute_turns(prompt, workspace, task, orchestrator_pid, max_turns, config)
      end

    final = resolve_completion(iterations)
    run_turn = fn prompt -> fix_turn(prompt, workspace, task, config, orchestrator_pid) end

    final = Shep.Goal.verify_loop(final, task, workspace, config, orchestrator_pid, run_turn)

    {final, pr_url} =
      case Shep.AgentRunner.PR.create(final, task, workspace, config) do
        {:ok, url} ->
          {Shep.Goal.ci_loop(final, url, task, workspace, config, orchestrator_pid, run_turn), url}

        :none ->
          {final, nil}

        {:error, reason} ->
          Logger.error("Push or PR creation failed for task #{task.id}: #{reason}")

          {%Shep.Completion.Failed{
             reason: "push/PR failed: #{Shep.Goal.tail(reason, 300)}",
             recoverable: false
           }, nil}
      end

    Workspace.cleanup(workspace, task, final, config)
    finish(task, iterations, final, pr_url, where, started_at)
  end

  defp finish(task, iterations, final, pr_url, where, started_at) do
    duration = System.monotonic_time(:millisecond) - started_at

    result = %Shep.RunResult{
      iterations: iterations,
      completion: final,
      branch_name: task.branch,
      worktree_path: where,
      duration_ms: duration,
      pr_url: pr_url
    }

    :telemetry.execute(
      [:shep, :agent, :stop],
      %{duration_ms: duration},
      %{task_id: task.id, completion: final}
    )

    result
  end

  defp resolve_workspace(task, %{resume_worktree: path}, config) when is_binary(path) do
    case Workspace.reattach(task, path, config) do
      {:ok, workspace} -> {:ok, workspace, true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_workspace(task, _opts, config) do
    case Workspace.prepare(task, config) do
      {:ok, workspace} -> {:ok, workspace, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_resume_turns(workspace, task, orchestrator_pid, max_turns, config) do
    agent_cmd = agent_command(task.agent, config)
    args = Exec.agent_module(task.agent).build_resume_args(task.id, model_for(task, config))
    idle_ms = idle_timeout_ms(config)

    iteration =
      run_single_turn_with_args(workspace, agent_cmd, args, task, orchestrator_pid, idle_ms)

    case iteration.completion do
      %Shep.Completion.Complete{} ->
        [iteration]

      %Shep.Completion.Failed{} ->
        [iteration]

      _ ->
        prompt = Shep.PromptBuilder.build_expanded(task, Workspace.prompt_cwd(workspace, config))

        remaining =
          execute_turns(prompt, workspace, task, orchestrator_pid, max_turns - 1, config)

        [iteration | remaining]
    end
  end

  defp execute_turns(prompt, workspace, task, orchestrator_pid, max_turns, config) do
    agent_cmd = agent_command(task.agent, config)
    idle_ms = idle_timeout_ms(config)
    model = model_for(task, config)

    do_turns(
      prompt,
      workspace,
      task,
      orchestrator_pid,
      {agent_cmd, model, idle_ms},
      max_turns,
      1,
      []
    )
  end

  defp do_turns(_prompt, _path, _task, _pid, _agent, max, turn, acc) when turn > max do
    Enum.reverse(acc)
  end

  defp do_turns(prompt, ws, task, orchestrator_pid, {cmd, model, idle_ms} = agent, max, turn, acc) do
    iteration = run_single_turn(cmd, model, prompt, ws, task, orchestrator_pid, idle_ms)
    new_acc = [iteration | acc]

    case iteration.completion do
      %Shep.Completion.Complete{} -> Enum.reverse(new_acc)
      %Shep.Completion.Failed{} -> Enum.reverse(new_acc)
      _ when turn >= max -> Enum.reverse(new_acc)
      _ -> do_turns(prompt, ws, task, orchestrator_pid, agent, max, turn + 1, new_acc)
    end
  end

  defp run_single_turn(agent_cmd, model, prompt, workspace, task, orchestrator_pid, idle_ms) do
    args = Exec.agent_module(task.agent).build_args(prompt, task.id, model)
    run_single_turn_with_args(workspace, agent_cmd, args, task, orchestrator_pid, idle_ms)
  end

  defp run_single_turn_with_args(workspace, agent_cmd, args, task, orchestrator_pid, idle_ms) do
    case Workspace.agent_spec(workspace, agent_cmd, args) do
      {:ok, exe, argv, cwd} -> Exec.run(exe, argv, cwd, task, orchestrator_pid, idle_ms)
      {:error, missing} -> Exec.executable_not_found(missing)
    end
  end

  defp idle_timeout_ms(config) do
    get_in(config, ["agent", "idle_timeout_ms"]) || 600_000
  end

  @doc """
  The model a task runs on: its `shep:model:` override, else `agent.model`.

  Codex takes no default: `agent.model` names a Claude model, so an
  un-overridden Codex task runs on whatever the Codex CLI defaults to.
  """
  @spec model_for(Shep.Task.t(), map()) :: String.t() | nil
  def model_for(%Shep.Task{model: model}, _config) when is_binary(model), do: model
  def model_for(%Shep.Task{agent: :codex}, _config), do: nil
  def model_for(_task, config), do: get_in(config, ["agent", "model"])

  defp log_model_override(%Shep.Task{id: id, model: model}) when is_binary(model),
    do: Logger.info("model override for task #{id}: #{model}")

  defp log_model_override(_task), do: :ok

  defp agent_command(:codex, _config), do: "codex"

  defp agent_command(_agent, config) do
    get_in(config, ["agent", "command"]) || "claude"
  end

  defp resolve_completion([]),
    do: %Shep.Completion.Failed{reason: "no iterations", recoverable: false}

  defp resolve_completion(iterations) do
    last = List.last(iterations)

    cond do
      last.completion != nil -> last.completion
      last.exit_code == 0 -> %Shep.Completion.Complete{summary: "completed without signal"}
      true -> %Shep.Completion.Failed{reason: "exit code #{last.exit_code}", recoverable: true}
    end
  end

  @doc "Run a single fix turn: continue the agent session with a new prompt."
  @spec fix_turn(String.t(), Workspace.t(), Shep.Task.t(), map(), pid()) ::
          Shep.IterationResult.t()
  def fix_turn(prompt, workspace, task, config, opid) do
    agent_cmd = agent_command(task.agent, config)
    args = Shep.AgentRunner.Claude.build_continue_args(prompt, task.id, model_for(task, config))
    run_single_turn_with_args(workspace, agent_cmd, args, task, opid, idle_timeout_ms(config))
  end
end
