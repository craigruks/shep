defmodule Shep.AgentRunner do
  @moduledoc "Executes a single task: worktree → prompt → Claude Code → cleanup."

  require Logger

  alias Shep.AgentRunner.Exec

  @doc "Run a task end-to-end. Called inside a Task.Supervisor-spawned process."
  @spec run(Shep.Task.t(), pid(), map()) :: Shep.RunResult.t()
  def run(%Shep.Task{} = task, orchestrator_pid, opts \\ %{}) do
    Logger.metadata(task_id: task.id, task_type: task.type)
    started_at = System.monotonic_time(:millisecond)
    config = opts[:config] || Shep.Config.current!()
    max_turns = get_in(config, ["agent", "max_turns"]) || 10

    :telemetry.execute([:shep, :agent, :start], %{}, %{task_id: task.id, task_type: task.type})

    case resolve_worktree(task, opts, config) do
      {:ok, worktree_path, resuming?} ->
        Logger.info("Worktree ready for task #{task.id}: #{worktree_path}")

        Logger.info(
          "agent phase: streaming to .shep/runs/#{task.id}.stdout.log; " <>
            "this log stays quiet except gap heartbeats until verify"
        )

        session = Exec.agent_module(task.agent).session_name(task.id)

        send(
          orchestrator_pid,
          {:agent_meta, task.id, %{worktree_path: worktree_path, session_name: session}}
        )

        unless resuming?, do: run_hooks(config, worktree_path)

        iterations =
          if resuming? do
            execute_resume_turns(worktree_path, task, orchestrator_pid, max_turns, config)
          else
            built_prompt = Shep.PromptBuilder.build(task)
            prompt = Shep.Prompt.expand(built_prompt, task.prompt_args, worktree_path)
            execute_turns(prompt, worktree_path, task, orchestrator_pid, max_turns, config)
          end

        final = resolve_completion(iterations)
        run_turn = fn prompt -> fix_turn(prompt, worktree_path, task, config, orchestrator_pid) end

        final =
          Shep.Goal.verify_loop(final, task, worktree_path, config, orchestrator_pid, run_turn)

        {final, pr_url} =
          case Shep.AgentRunner.PR.create(final, task, worktree_path, config) do
            {:ok, url} ->
              {Shep.Goal.ci_loop(
                 final,
                 url,
                 task,
                 worktree_path,
                 config,
                 orchestrator_pid,
                 run_turn
               ), url}

            :none ->
              {final, nil}

            {:error, reason} ->
              Logger.error("Push or PR creation failed for task #{task.id}: #{reason}")

              {%Shep.Completion.Failed{
                 reason: "push/PR failed: #{Shep.Goal.tail(reason, 300)}",
                 recoverable: false
               }, nil}
          end

        cleanup_worktree(worktree_path, final, config)
        duration = System.monotonic_time(:millisecond) - started_at

        result = %Shep.RunResult{
          iterations: iterations,
          completion: final,
          branch_name: task.branch,
          worktree_path: worktree_path,
          duration_ms: duration,
          pr_url: pr_url
        }

        :telemetry.execute(
          [:shep, :agent, :stop],
          %{duration_ms: duration},
          %{task_id: task.id, completion: final}
        )

        result

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

  defp resolve_worktree(_task, %{resume_worktree: path}, _config) when is_binary(path) do
    if File.dir?(path) do
      {:ok, path, true}
    else
      {:error, "resume worktree not found: #{path}"}
    end
  end

  defp resolve_worktree(task, _opts, config) do
    root = get_in(config, ["workspace", "root"])
    repo = get_in(config, ["workspace", "repo"]) || "."
    File.mkdir_p!(root)

    case Shep.Worktree.create(task.branch, task.base_branch, root, repo) do
      {:ok, path} -> {:ok, path, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_resume_turns(worktree_path, task, orchestrator_pid, max_turns, config) do
    agent_cmd = agent_command(task.agent, config)
    args = Exec.agent_module(task.agent).build_resume_args(task.id, agent_model(config))
    idle_ms = idle_timeout_ms(config)

    iteration =
      run_single_turn_with_args(agent_cmd, args, worktree_path, task, orchestrator_pid, idle_ms)

    case iteration.completion do
      %Shep.Completion.Complete{} ->
        [iteration]

      %Shep.Completion.Failed{} ->
        [iteration]

      _ ->
        built_prompt = Shep.PromptBuilder.build(task)
        prompt = Shep.Prompt.expand(built_prompt, task.prompt_args, worktree_path)

        remaining =
          execute_turns(prompt, worktree_path, task, orchestrator_pid, max_turns - 1, config)

        [iteration | remaining]
    end
  end

  defp execute_turns(prompt, worktree_path, task, orchestrator_pid, max_turns, config) do
    agent_cmd = agent_command(task.agent, config)
    idle_ms = idle_timeout_ms(config)
    model = agent_model(config)

    do_turns(
      prompt,
      worktree_path,
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

  defp do_turns(prompt, path, task, orchestrator_pid, {cmd, model, idle_ms} = agent, max, turn, acc) do
    iteration = run_single_turn(cmd, model, prompt, path, task, orchestrator_pid, idle_ms)
    new_acc = [iteration | acc]

    case iteration.completion do
      %Shep.Completion.Complete{} -> Enum.reverse(new_acc)
      %Shep.Completion.Failed{} -> Enum.reverse(new_acc)
      _ when turn >= max -> Enum.reverse(new_acc)
      _ -> do_turns(prompt, path, task, orchestrator_pid, agent, max, turn + 1, new_acc)
    end
  end

  defp run_single_turn(agent_cmd, model, prompt, cwd, task, orchestrator_pid, idle_ms) do
    args = Exec.agent_module(task.agent).build_args(prompt, task.id, model)
    run_single_turn_with_args(agent_cmd, args, cwd, task, orchestrator_pid, idle_ms)
  end

  defp run_single_turn_with_args(agent_cmd, args, cwd, task, orchestrator_pid, idle_ms) do
    case Exec.resolve_executable(agent_cmd) do
      nil -> Exec.executable_not_found(agent_cmd)
      exe -> Exec.run(exe, args, cwd, task, orchestrator_pid, idle_ms)
    end
  end

  defp idle_timeout_ms(config) do
    get_in(config, ["agent", "idle_timeout_ms"]) || 600_000
  end

  defp agent_model(config) do
    get_in(config, ["agent", "model"])
  end

  defp agent_command(:codex, _config), do: "codex"

  defp agent_command(_agent, config) do
    get_in(config, ["agent", "command"]) || "claude"
  end

  defp run_hooks(config, worktree_path) do
    Shep.Hooks.run_lifecycle(config, "on_worktree_ready", worktree_path)
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
  @spec fix_turn(String.t(), String.t(), Shep.Task.t(), map(), pid()) :: Shep.IterationResult.t()
  def fix_turn(prompt, wt, task, config, opid) do
    agent_cmd = agent_command(task.agent, config)
    args = Shep.AgentRunner.Claude.build_continue_args(prompt, task.id, agent_model(config))
    run_single_turn_with_args(agent_cmd, args, wt, task, opid, idle_timeout_ms(config))
  end

  defp cleanup_worktree(path, completion, config) do
    repo = get_in(config, ["workspace", "repo"]) || "."

    case completion do
      %Shep.Completion.Failed{} ->
        Logger.info("Preserving worktree for failed task: #{path}")

      _ ->
        Shep.Worktree.remove(path, repo)
    end
  end
end
