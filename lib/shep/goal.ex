defmodule Shep.Goal do
  @moduledoc """
  The goal contract: a task is not done until its PR has green CI.

  Two loops enforce it, cheapest first. The verify loop runs the
  configured `goal.verify` command in the worktree before any PR
  exists; failures go back to the same agent session for a fix turn.
  The CI fix loop feeds failing check logs back to the session after
  a red run. Helpers here are pure or shell-thin so they stay testable.

  Both loops take a `run_turn` function — `(prompt) -> IterationResult` —
  so the goal contract never depends on the agent runner directly (the
  runner injects the capability, avoiding a module cycle).
  """

  require Logger

  @tail_bytes 8_000

  @typedoc "Runs one fix turn in the agent session, returning its result."
  @type run_turn :: (String.t() -> Shep.IterationResult.t())

  @doc """
  Run the pre-PR verify loop. A complete Claude task runs the configured
  `goal.verify` command in the worktree; a failure feeds a fix turn back
  through `run_turn` and re-verifies, up to `goal.verify_fixes` attempts.
  Returns the (possibly downgraded) completion.
  """
  @spec verify_loop(struct(), Shep.Task.t(), String.t(), map(), pid(), run_turn()) :: struct()
  def verify_loop(
        %Shep.Completion.Complete{} = final,
        %{demo: false, agent: :claude} = task,
        worktree_path,
        config,
        orchestrator_pid,
        run_turn
      ) do
    case get_in(config, ["goal", "verify"]) do
      nil ->
        final

      verify_cmd ->
        max = get_in(config, ["goal", "verify_fixes"]) || 2

        do_verify(
          final,
          task,
          worktree_path,
          config,
          orchestrator_pid,
          verify_cmd,
          0,
          max,
          run_turn
        )
    end
  end

  def verify_loop(final, _task, _path, _config, _pid, _run_turn), do: final

  defp do_verify(final, task, wt, config, opid, verify_cmd, attempt, max, run_turn) do
    send(opid, {:agent_output, task.id, "[goal] running verify (attempt #{attempt + 1})"})

    case run_verify(verify_cmd, wt) do
      {:ok, _out} ->
        Logger.info("Verify passed for task #{task.id}")
        final

      {:error, out} when attempt < max ->
        Logger.warning("Verify failed for task #{task.id}, fix turn #{attempt + 1}/#{max}")
        prompt = fix_prompt(:verify, attempt + 1, max, out, verify_cmd)
        iteration = run_turn.(prompt)

        case iteration.completion do
          %Shep.Completion.Failed{} = failed ->
            failed

          _ ->
            do_verify(final, task, wt, config, opid, verify_cmd, attempt + 1, max, run_turn)
        end

      {:error, out} ->
        %Shep.Completion.Failed{
          reason: "verify failed after #{max} fix attempts: #{tail(out, 400)}",
          recoverable: false
        }
    end
  end

  @doc """
  Run the post-PR CI loop. On a red run the failing check logs feed a
  fix turn through `run_turn` and the branch is re-pushed so CI re-runs,
  up to `goal.ci_fixes` attempts (Claude only). Returns the completion,
  downgraded to `Failed` if the goal is not reached.
  """
  @spec ci_loop(struct(), String.t(), Shep.Task.t(), String.t(), map(), pid(), run_turn()) ::
          struct()
  def ci_loop(final, _pr_url, %{no_merge: true} = task, _wt, _config, _pid, _run_turn) do
    Logger.info("Skipping CI watch for task #{task.id} (no-merge)")
    final
  end

  def ci_loop(final, pr_url, task, wt, config, opid, run_turn) do
    repo = get_in(config, ["tracker", "repo"])
    pr_number = pr_url |> String.split("/") |> List.last()
    max = get_in(config, ["goal", "ci_fixes"]) || 2
    do_ci(final, repo, pr_number, task, wt, config, opid, 0, max, run_turn)
  end

  defp do_ci(final, repo, pr, task, wt, config, opid, attempt, max, run_turn) do
    case Shep.CIWatch.watch(repo, pr, max_retries: 1) do
      :passed ->
        Logger.info("CI passed for task #{task.id}")
        Shep.Tracker.update_status(task.id, "in-review")
        final

      {:failed, reason} when attempt < max and task.agent == :claude ->
        Logger.warning("CI failed for task #{task.id}, fix turn #{attempt + 1}/#{max}: #{reason}")
        logs = Shep.CIWatch.failure_logs(repo, pr)
        prompt = fix_prompt(:ci, attempt + 1, max, logs, nil)
        _iteration = run_turn.(prompt)

        case Shep.AgentRunner.PR.push_branch(task, wt) do
          :ok ->
            do_ci(final, repo, pr, task, wt, config, opid, attempt + 1, max, run_turn)

          {:error, push_err} ->
            give_up(task, "push failed during CI fix: #{tail(push_err, 300)}")
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

  @doc "Run the verify command in the worktree. Returns output either way."
  @spec run_verify(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run_verify(cmd, cwd) when is_binary(cmd) and is_binary(cwd) do
    case System.cmd("/bin/sh", ["-c", cmd], cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _code} -> {:error, out}
    end
  end

  @doc "Last `bytes` of a string, for feeding logs to a fix turn."
  @spec tail(String.t(), non_neg_integer()) :: String.t()
  def tail(s, bytes \\ @tail_bytes)
  def tail(s, bytes) when is_binary(s) and byte_size(s) <= bytes, do: s

  def tail(s, bytes) when is_binary(s) do
    binary_part(s, byte_size(s) - bytes, bytes)
  end

  @doc "Build the prompt for a fix turn in the same agent session."
  @spec fix_prompt(:verify | :ci, pos_integer(), pos_integer(), String.t(), String.t() | nil) ::
          String.t()
  def fix_prompt(:verify, attempt, max, output, cmd) do
    """
    The verification command failed, so this task is not complete yet.
    Fix attempt #{attempt} of #{max}.

    Command: #{cmd}

    Output (tail):
    ```
    #{tail(output)}
    ```

    Fix the failures, re-run the command until it passes, and commit your
    changes. Do NOT push or create pull requests; the orchestrator handles
    that. If the failure is genuinely unfixable, emit a failed completion
    signal explaining why.
    """
  end

  def fix_prompt(:ci, attempt, max, logs, _cmd) do
    """
    CI failed on the pull request for this task. The goal is a PR with
    green CI, so this task is not complete yet. Fix attempt #{attempt} of #{max}.

    Failing check logs (tail):
    ```
    #{tail(logs)}
    ```

    Fix the failures, run the relevant checks locally, and commit your
    changes. Do NOT push or create pull requests; the orchestrator pushes
    and CI re-runs. If the failure is genuinely unfixable, emit a failed
    completion signal explaining why.
    """
  end
end
