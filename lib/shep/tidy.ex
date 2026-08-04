defmodule Shep.Tidy do
  @moduledoc """
  Reclaim workspaces no live task owns.

  A worktree outlives its run three ways: the task was interrupted, so the
  runner's cleanup died with the process; it failed and was preserved for
  post-mortem; or it was dirty and `Worktree.remove` refused. Nothing ever
  reclaimed them afterwards — boot only prunes registrations for
  directories that are already gone — so they pile up until someone
  notices them in a UI.

  The safety rule is deliberately not "the issue looks finished". A label
  says what a tracker believes; it does not say whether this directory
  holds the only copy of something. A worktree is reclaimed only when it
  holds nothing that is not already on a remote:

    * no task is running or paused in it,
    * the tree is clean, and
    * its HEAD is contained in some remote branch — pushed, or merged.

  Decided from git alone, so it needs no tracker call, works offline
  (minus the freshness of one fetch), and cannot be fooled by a stale
  label. Anything else is reported and left alone.

  One consequence worth stating plainly: "clean" is git's definition, and
  git does not count ignored files. A worktree holding only a hook-written
  `.env` and `node_modules` reads as clean and is reclaimed. That is the
  intent — a worktree is disposable and the hook rewrites both on the next
  dispatch — but anything you drop in by hand and gitignore goes with it.
  """

  require Logger

  @type decision :: :reap | :busy | :dirty | :unpushed | :foreign | :unreadable

  @type entry :: %{
          path: String.t(),
          branch: String.t() | nil,
          decision: decision(),
          detail: String.t()
        }

  @doc """
  Survey and reclaim. Returns a report; pass `dry_run: true` to survey only.

  Runs on the daemon when one is reachable, so `busy` reflects live state.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    config = config()
    root = get_in(config, ["workspace", "root"])
    repo = get_in(config, ["workspace", "repo"]) || "."
    dry_run? = Keyword.get(opts, :dry_run, false)

    entries = survey(config, busy_paths())

    reaped =
      if dry_run? do
        []
      else
        entries
        |> Enum.filter(&(&1.decision == :reap))
        |> Enum.map(&reclaim(&1, repo))
        |> Enum.reject(&is_nil/1)
      end

    sandboxes = tidy_sandboxes(config, dry_run?)

    %{
      root: root,
      dry_run: dry_run?,
      entries: entries,
      reaped: reaped,
      sandboxes: sandboxes
    }
  end

  @doc """
  Classify every worktree under the configured root.

  `busy` is the set of paths a running or paused task owns.
  """
  @spec survey(map(), MapSet.t()) :: [entry()]
  def survey(config, busy \\ MapSet.new()) do
    root = get_in(config, ["workspace", "root"])
    repo = get_in(config, ["workspace", "repo"]) || "."

    if is_binary(root) and File.dir?(root) do
      # One fetch keeps remote-tracking refs honest; without it a branch
      # pushed by another process still looks unpushed here.
      _ = System.cmd("git", ["-C", repo, "fetch", "--quiet", "origin"], stderr_to_stdout: true)

      root
      |> Shep.Worktree.list()
      |> Enum.map(&classify(&1, busy, common_dir(repo)))
    else
      []
    end
  end

  @doc """
  Whether a worktree holds anything that is not already on a remote.

  `owner` is the git common dir of the clone this daemon manages. Flocks
  can share a worktree root — Shep and another repo both pointing at
  `~/code/shep_worktrees` — and `git worktree remove` only works from the
  clone that owns the worktree, so anything belonging to a different one
  is reported and left to its own daemon.
  """
  @spec classify(String.t(), MapSet.t(), String.t() | nil) :: entry()
  def classify(path, busy \\ MapSet.new(), owner \\ nil) do
    cond do
      MapSet.member?(busy, Path.expand(path)) ->
        entry(path, :busy, "a live task owns it")

      true ->
        case branch_of(path) do
          nil ->
            entry(path, :unreadable, "not a readable git worktree")

          branch ->
            classify_owned(path, branch, owner)
        end
    end
  end

  defp classify_owned(path, branch, owner) do
    if foreign?(path, owner) do
      entry(path, :foreign, "belongs to another clone", branch)
    else
      classify_git(path, branch)
    end
  end

  # nil owner means the caller did not scope the sweep (a bare classify/1
  # in a test or an iex session), so ownership is not checked.
  defp foreign?(_path, nil), do: false
  defp foreign?(path, owner), do: common_dir(path) not in [nil, owner]

  defp common_dir(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.trim() |> Path.expand()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp classify_git(path, branch) do
    cond do
      dirty?(path) ->
        entry(path, :dirty, "uncommitted changes", branch)

      remote_refs_containing_head(path) == [] ->
        entry(path, :unpushed, "HEAD is on no remote branch", branch)

      true ->
        entry(path, :reap, "fully pushed and clean", branch)
    end
  end

  defp entry(path, decision, detail, branch \\ nil) do
    %{path: path, branch: branch, decision: decision, detail: detail}
  end

  defp reclaim(%{path: path, branch: branch}, repo) do
    case Shep.Worktree.remove(path, repo) do
      :ok ->
        # Safe by construction: we only get here when HEAD is already on a
        # remote, so deleting the local branch discards no unique commit.
        if branch,
          do: System.cmd("git", ["-C", repo, "branch", "-D", branch], stderr_to_stdout: true)

        Logger.info("Tidy reclaimed worktree #{path} (#{branch})")
        path

      {:error, reason} ->
        Logger.warning("Tidy could not reclaim #{path}: #{reason}")
        nil
    end
  end

  # Paths a running or paused task owns. Both the recorded path and the
  # path the task's branch implies, so a worktree created moments ago —
  # before the runner reported its location — is never mistaken for junk.
  defp busy_paths do
    snapshot = Shep.Orchestrator.snapshot()
    root = get_in(config(), ["workspace", "root"])

    [snapshot[:running] || %{}, snapshot[:paused] || %{}]
    |> Enum.flat_map(&Map.values/1)
    |> Enum.flat_map(fn info ->
      [info[:worktree_path], implied_path(info[:branch], root)]
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> MapSet.new()
  rescue
    # No orchestrator in this VM: treat nothing as busy rather than crash.
    _ -> MapSet.new()
  end

  defp implied_path(branch, root) when is_binary(branch) and is_binary(root),
    do: Shep.Worktree.path_for(branch, root)

  defp implied_path(_branch, _root), do: nil

  defp branch_of(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp dirty?(path), do: Shep.Worktree.has_uncommitted_changes?(path)

  defp remote_refs_containing_head(path) do
    case System.cmd("git", ["-C", path, "branch", "-r", "--contains", "HEAD"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      _ -> []
    end
  rescue
    _ -> []
  end

  # Sandboxes have their own reclaim path (`Sandbox.sweep/2`); tidy runs it
  # on the same schedule so both kinds of workspace are covered by one job.
  defp tidy_sandboxes(config, dry_run?) do
    snapshot = Shep.Orchestrator.snapshot()

    keep =
      [snapshot[:running] || %{}, snapshot[:paused] || %{}]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.map(&Shep.Sandbox.name_for_id/1)

    cond do
      not sandboxes_configured?(config) -> []
      dry_run? -> []
      true -> reap_sandboxes(config, keep)
    end
  rescue
    _ -> []
  end

  defp reap_sandboxes(config, keep) do
    case Shep.Sandbox.sweep(config, keep) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end

  defp sandboxes_configured?(config) do
    case get_in(config, ["sandbox", "snapshot"]) do
      snapshot when is_binary(snapshot) and snapshot != "" -> true
      _ -> false
    end
  end

  defp config do
    Shep.Config.current!()
  rescue
    _ -> %{}
  end
end
