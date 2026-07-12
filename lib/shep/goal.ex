defmodule Shep.Goal do
  @moduledoc """
  The goal contract: a task is not done until its PR has green CI.

  Two loops enforce it, cheapest first. The verify loop runs the
  configured `goal.verify` command in the worktree before any PR
  exists; failures go back to the same agent session for a fix turn.
  The CI fix loop feeds failing check logs back to the session after
  a red run. Helpers here are pure or shell-thin so they stay testable.
  """

  @tail_bytes 8_000

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
