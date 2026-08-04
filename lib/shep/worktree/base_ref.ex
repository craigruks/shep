defmodule Shep.Worktree.BaseRef do
  @moduledoc """
  The ref a task's branch is cut from, refreshed before it is cut.

  `workspace.repo` is a long-lived clone that nothing else refreshes, so
  `git worktree add … staging` hands the agent whatever that clone last
  saw. The failure is silent: the branch is valid, the agent runs, and the
  staleness only surfaces later as a merge conflict or a red PR. So the
  fetch happens here, before the cut, and the worktree is cut from the
  remote-tracking ref the fetch just moved — not from the local branch,
  which a fetch does not touch.

  One fetch at a time per repo. Concurrent dispatches share one
  `workspace.repo`, and git's ref and `FETCH_HEAD` locks are first-come:
  the loser of that race fails, and a hook-level workaround can only
  discover it after the worktree exists. A `:global` lock keyed by the
  repo path serializes the fetch; `git worktree add` itself stays
  concurrent.

  A base branch with no remote-tracking ref has nothing to refresh — the
  demo cuts from the current local branch — and is used as given.
  """

  require Logger

  @remote "origin"
  @fetch_timeout_ms 120_000

  @doc """
  The ref to cut a worktree from, after refreshing it from `#{@remote}`.

  Returns `{:error, reason}` when the fetch fails rather than falling back
  to the stale ref: a dispatch retried is cheaper than an agent working
  from the wrong base.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(repo, base_branch) when is_binary(repo) and is_binary(base_branch) do
    branch = String.replace_prefix(base_branch, @remote <> "/", "")
    remote_ref = "#{@remote}/#{branch}"

    if tracked?(repo, remote_ref) do
      with :ok <- locked_fetch(repo, branch), do: {:ok, remote_ref}
    else
      Logger.debug("No #{remote_ref} in #{repo}: cutting from #{base_branch} without a fetch")
      {:ok, base_branch}
    end
  end

  defp tracked?(repo, remote_ref) do
    args = ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/remotes/#{remote_ref}"]
    match?({_out, 0}, System.cmd("git", args, stderr_to_stdout: true))
  end

  # Keyed by the expanded repo path, so two flocks sharing a clone share
  # the lock and two flocks on different clones never block each other.
  defp locked_fetch(repo, branch) do
    lock = {{__MODULE__, Path.expand(repo)}, self()}

    case :global.trans(lock, fn -> fetch(repo, branch) end, [node()]) do
      :aborted -> {:error, "could not acquire the fetch lock for #{repo}"}
      result -> result
    end
  end

  # Bounded, because the lock is held for the duration: a fetch hung on the
  # network would otherwise stall every later dispatch, not just this one.
  defp fetch(repo, branch) do
    refspec = "+refs/heads/#{branch}:refs/remotes/#{@remote}/#{branch}"
    args = ["-C", repo, "fetch", "--quiet", @remote, refspec]
    task = Task.async(fn -> System.cmd("git", args, stderr_to_stdout: true) end)

    case Task.yield(task, @fetch_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} ->
        Logger.info("Fetched #{@remote}/#{branch} into #{repo}")
        :ok

      {:ok, {out, _code}} ->
        {:error, "git fetch #{@remote} #{branch} failed: #{String.trim(out)}"}

      _timeout ->
        {:error, "git fetch #{@remote} #{branch} timed out after #{@fetch_timeout_ms}ms"}
    end
  end
end
