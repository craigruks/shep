defmodule Shep.AgentRunner do
  @moduledoc "Executes a single task: worktree → prompt → Claude Code → cleanup."

  require Logger

  @max_line_length 65_536

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
        session = agent_module(task.agent).session_name(task.id)

        send(
          orchestrator_pid,
          {:agent_meta, task.id, %{worktree_path: worktree_path, session_name: session}}
        )

        unless resuming?, do: run_hooks(config, worktree_path)

        iterations =
          if resuming? do
            execute_resume_turns(worktree_path, task, orchestrator_pid, max_turns, config)
          else
            {built_prompt, _timeout} = Shep.PromptBuilder.build(task)
            prompt = Shep.Prompt.expand(built_prompt, task.prompt_args, worktree_path)
            execute_turns(prompt, worktree_path, task, orchestrator_pid, max_turns, config)
          end

        final = resolve_completion(iterations)
        final = run_verify_loop(final, task, worktree_path, config, orchestrator_pid)

        {final, pr_url} =
          case create_pr(final, task, worktree_path, config) do
            {:ok, url} ->
              {run_ci_loop(final, url, task, worktree_path, config, orchestrator_pid), url}

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
    args = agent_module(task.agent).build_resume_args(task.id)

    iteration = run_single_turn_with_args(agent_cmd, args, worktree_path, task, orchestrator_pid)

    case iteration.completion do
      %Shep.Completion.Complete{} ->
        [iteration]

      %Shep.Completion.Failed{} ->
        [iteration]

      _ ->
        {built_prompt, _timeout} = Shep.PromptBuilder.build(task)
        prompt = Shep.Prompt.expand(built_prompt, task.prompt_args, worktree_path)

        remaining =
          execute_turns(prompt, worktree_path, task, orchestrator_pid, max_turns - 1, config)

        [iteration | remaining]
    end
  end

  defp execute_turns(prompt, worktree_path, task, orchestrator_pid, max_turns, config) do
    agent_cmd = agent_command(task.agent, config)
    do_turns(prompt, worktree_path, task, orchestrator_pid, agent_cmd, max_turns, 1, [])
  end

  defp do_turns(_prompt, _path, _task, _pid, _cmd, max, turn, acc) when turn > max do
    Enum.reverse(acc)
  end

  defp do_turns(prompt, path, task, orchestrator_pid, cmd, max, turn, acc) do
    iteration = run_single_turn(cmd, prompt, path, task, orchestrator_pid)
    new_acc = [iteration | acc]

    case iteration.completion do
      %Shep.Completion.Complete{} -> Enum.reverse(new_acc)
      %Shep.Completion.Failed{} -> Enum.reverse(new_acc)
      _ when turn >= max -> Enum.reverse(new_acc)
      _ -> do_turns(prompt, path, task, orchestrator_pid, cmd, max, turn + 1, new_acc)
    end
  end

  defp run_single_turn(agent_cmd, prompt, cwd, task, orchestrator_pid) do
    args = agent_module(task.agent).build_args(prompt, task.id)
    run_single_turn_with_args(agent_cmd, args, cwd, task, orchestrator_pid)
  end

  defp run_single_turn_with_args(agent_cmd, args, cwd, task, orchestrator_pid) do
    case resolve_executable(agent_cmd) do
      nil -> executable_not_found(agent_cmd)
      exe -> run_port(exe, args, cwd, task, orchestrator_pid)
    end
  end

  @doc "Resolve an agent command: bare names via PATH, paths relative to cwd."
  @spec resolve_executable(String.t()) :: String.t() | nil
  def resolve_executable(cmd) do
    if String.contains?(cmd, "/") do
      path = Path.expand(cmd)
      if File.exists?(path), do: path, else: nil
    else
      System.find_executable(cmd)
    end
  end

  defp executable_not_found(agent_cmd) do
    reason = "agent command not found: #{agent_cmd}"
    Logger.error(reason)

    %Shep.IterationResult{
      stdout: "",
      stderr: reason,
      exit_code: 127,
      completion: %Shep.Completion.Failed{reason: reason, recoverable: false},
      duration_ms: 0
    }
  end

  defp run_port(exe, args, cwd, task, orchestrator_pid) do
    started_at = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        {:line, @max_line_length},
        :stderr_to_stdout,
        {:cd, cwd},
        {:args, args}
      ])

    {stdout, exit_code} = collect_port_output(port, task.id, orchestrator_pid)
    duration = System.monotonic_time(:millisecond) - started_at

    completion =
      stdout
      |> String.split("\n")
      |> Enum.find_value(&parse_completion_from_line(&1, task.agent))

    %Shep.IterationResult{
      stdout: stdout,
      stderr: "",
      exit_code: exit_code,
      completion: completion,
      duration_ms: duration
    }
  end

  @doc false
  def parse_completion_from_line_for_test(line), do: parse_completion_from_line(line, :claude)

  defp parse_completion_from_line(line, agent) do
    text = extract_text_from_json(line, agent)
    Shep.Completion.parse(text)
  end

  defp extract_text_from_json(line, agent) do
    agent_module(agent).extract_text(line)
  end

  defp agent_module(:claude), do: Shep.AgentRunner.Claude
  defp agent_module(:codex), do: Shep.AgentRunner.Codex

  defp agent_command(:codex, _config), do: "codex"

  defp agent_command(_agent, config) do
    get_in(config, ["agent", "command"]) || "claude"
  end

  defp collect_port_output(port, task_id, orchestrator_pid) do
    collect_port_output(port, task_id, orchestrator_pid, [], nil)
  end

  defp collect_port_output(port, task_id, orchestrator_pid, lines, exit_code) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        send(orchestrator_pid, {:agent_output, task_id, line})
        :telemetry.execute([:shep, :agent, :stdout], %{}, %{task_id: task_id, line: line})
        collect_port_output(port, task_id, orchestrator_pid, [line | lines], exit_code)

      {^port, {:data, {:noeol, line}}} ->
        collect_port_output(port, task_id, orchestrator_pid, [line | lines], exit_code)

      {^port, {:exit_status, code}} ->
        {lines |> Enum.reverse() |> Enum.join("\n"), code}
    after
      600_000 ->
        Port.close(port)
        kill_port_os_pid(port)
        {lines |> Enum.reverse() |> Enum.join("\n"), 137}
    end
  end

  defp kill_port_os_pid(_port) do
    :ok
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

  # ── Goal: verify loop (pre-PR, cheapest failures first) ──

  defp run_verify_loop(
         %Shep.Completion.Complete{} = final,
         %{demo: false, agent: :claude} = task,
         worktree_path,
         config,
         orchestrator_pid
       ) do
    case get_in(config, ["goal", "verify"]) do
      nil ->
        final

      verify_cmd ->
        max = get_in(config, ["goal", "verify_fixes"]) || 2
        do_verify(final, task, worktree_path, config, orchestrator_pid, verify_cmd, 0, max)
    end
  end

  defp run_verify_loop(final, _task, _path, _config, _pid), do: final

  defp do_verify(final, task, wt, config, opid, verify_cmd, attempt, max) do
    send(opid, {:agent_output, task.id, "[goal] running verify (attempt #{attempt + 1})"})

    case Shep.Goal.run_verify(verify_cmd, wt) do
      {:ok, _out} ->
        Logger.info("Verify passed for task #{task.id}")
        final

      {:error, out} when attempt < max ->
        Logger.warning("Verify failed for task #{task.id}, fix turn #{attempt + 1}/#{max}")
        prompt = Shep.Goal.fix_prompt(:verify, attempt + 1, max, out, verify_cmd)
        iteration = run_fix_turn(prompt, wt, task, config, opid)

        case iteration.completion do
          %Shep.Completion.Failed{} = failed ->
            failed

          _ ->
            do_verify(final, task, wt, config, opid, verify_cmd, attempt + 1, max)
        end

      {:error, out} ->
        %Shep.Completion.Failed{
          reason: "verify failed after #{max} fix attempts: #{Shep.Goal.tail(out, 400)}",
          recoverable: false
        }
    end
  end

  # ── Goal: CI fix loop (post-PR) ──

  defp run_ci_loop(final, _pr_url, %{no_merge: true} = task, _wt, _config, _pid) do
    Logger.info("Skipping CI watch for task #{task.id} (no-merge)")
    final
  end

  defp run_ci_loop(final, pr_url, task, wt, config, opid) do
    repo = get_in(config, ["tracker", "repo"])
    pr_number = pr_url |> String.split("/") |> List.last()
    max = get_in(config, ["goal", "ci_fixes"]) || 2
    do_ci(final, repo, pr_number, task, wt, config, opid, 0, max)
  end

  defp do_ci(final, repo, pr, task, wt, config, opid, attempt, max) do
    case Shep.CIWatch.watch(repo, pr, max_retries: 1) do
      :passed ->
        Logger.info("CI passed for task #{task.id}")
        Shep.Tracker.update_status(task.id, "in-review")
        final

      {:failed, reason} when attempt < max and task.agent == :claude ->
        Logger.warning("CI failed for task #{task.id}, fix turn #{attempt + 1}/#{max}: #{reason}")
        logs = Shep.CIWatch.failure_logs(repo, pr)
        prompt = Shep.Goal.fix_prompt(:ci, attempt + 1, max, logs, nil)
        _iteration = run_fix_turn(prompt, wt, task, config, opid)

        case push_branch(task, wt) do
          :ok ->
            do_ci(final, repo, pr, task, wt, config, opid, attempt + 1, max)

          {:error, push_err} ->
            give_up(task, "push failed during CI fix: #{Shep.Goal.tail(push_err, 300)}")
        end

      {:failed, reason} ->
        give_up(task, "CI failed after #{attempt} fix attempts: #{reason}")
    end
  end

  defp give_up(task, reason) do
    Logger.error("Goal not reached for task #{task.id}: #{reason}")
    Shep.Tracker.update_status(task.id, "failed")
    Shep.Tracker.add_comment(task.id, "Goal not reached: #{reason}")
    Shep.Notifier.notify_failure(task, reason)
    %Shep.Completion.Failed{reason: reason, recoverable: false}
  end

  defp run_fix_turn(prompt, wt, task, config, opid) do
    agent_cmd = agent_command(task.agent, config)
    args = Shep.AgentRunner.Claude.build_continue_args(prompt, task.id)
    run_single_turn_with_args(agent_cmd, args, wt, task, opid)
  end

  # ── Push and PR ──

  defp create_pr(_completion, %{demo: true} = task, _path, _config) do
    Logger.info("Demo task #{task.id}: skipping push and PR creation")
    :none
  end

  defp create_pr(%Shep.Completion.Complete{summary: summary}, task, worktree_path, config) do
    if Shep.Worktree.has_uncommitted_changes?(worktree_path) do
      Logger.warning("Worktree has uncommitted changes, skipping PR")
      :none
    else
      push_and_pr(task, summary, config, worktree_path)
    end
  end

  defp create_pr(_completion, _task, _path, _config), do: :none

  @doc false
  def create_pr_for_test(completion, task, path, config) do
    create_pr(completion, task, path, config)
  end

  defp push_branch(task, cwd) do
    case System.cmd("git", ["push", "origin", task.branch], cd: cwd, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, _} -> {:error, err}
    end
  end

  defp push_and_pr(task, summary, config, cwd) do
    repo = get_in(config, ["tracker", "repo"])
    target = get_in(config, ["staging", "pr_target"]) || task.base_branch

    case push_branch(task, cwd) do
      :ok ->
        label =
          if task.no_merge,
            do: "shep:no-merge",
            else: "agent: claude-code"

        pr_args = [
          "pr",
          "create",
          "--repo",
          repo,
          "--base",
          target,
          "--head",
          task.branch,
          "--title",
          "[Shep] #{task.id}: #{String.slice(summary, 0, 60)}",
          "--body",
          "## Summary\n\n#{summary}\n\n---\nGenerated by Shep (task #{task.id})",
          "--label",
          label
        ]

        case System.cmd("gh", pr_args, stderr_to_stdout: true) do
          {url, 0} ->
            url = String.trim(url)
            Logger.info("PR created: #{url}")
            Shep.Tracker.update_status(task.id, "pr-created")
            {:ok, url}

          {err, _} ->
            {:error, "PR creation failed: #{err}"}
        end

      {:error, err} ->
        {:error, "push failed: #{err}"}
    end
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
