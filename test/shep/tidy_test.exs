defmodule Shep.TidyTest do
  # Real repos, real worktrees, a real bare remote — the classification is
  # the whole safety property, so it is tested against git rather than a
  # stand-in for git.
  use ExUnit.Case, async: true

  alias Shep.Tidy

  defp scratch do
    dir = Path.join(System.tmp_dir!(), "shep_tidy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp git!(repo, args) do
    {out, code} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  # A repo with a bare origin, so "is this commit on a remote?" is a real
  # question with a real answer.
  defp repo_with_remote do
    base = scratch()
    origin = Path.join(base, "origin.git")
    repo = Path.join(base, "repo")

    {_, 0} = System.cmd("git", ["init", "--bare", "-q", origin])
    {_, 0} = System.cmd("git", ["clone", "-q", origin, repo], stderr_to_stdout: true)
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-qm", "initial"])
    git!(repo, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    git!(repo, ["fetch", "-q", "origin"])

    {base, repo}
  end

  # Asked of git, exactly as production does, so symlinked temp paths
  # (/var vs /private/var on macOS) compare equal on both sides.
  defp common_dir(repo) do
    repo |> git!(["rev-parse", "--path-format=absolute", "--git-common-dir"]) |> String.trim()
  end

  defp worktree(repo, branch, root) do
    path = Path.join(root, String.replace(branch, "/", "_"))
    git!(repo, ["worktree", "add", "-q", "-b", branch, path, "HEAD"])
    path
  end

  describe "classify/2" do
    test "a clean, fully pushed worktree is reclaimable" do
      {base, repo} = repo_with_remote()
      root = Path.join(base, "worktrees")
      File.mkdir_p!(root)
      path = worktree(repo, "shep/1", root)
      git!(path, ["push", "-q", "origin", "shep/1"])
      git!(path, ["fetch", "-q", "origin"])

      assert %{decision: :reap, branch: "shep/1"} = Tidy.classify(path)
    end

    test "uncommitted changes are never reclaimed" do
      {base, repo} = repo_with_remote()
      root = Path.join(base, "worktrees")
      File.mkdir_p!(root)
      path = worktree(repo, "shep/2", root)
      git!(path, ["push", "-q", "origin", "shep/2"])
      File.write!(Path.join(path, "scratch.txt"), "work in progress")

      assert %{decision: :dirty} = Tidy.classify(path)
    end

    test "a commit that exists on no remote is never reclaimed" do
      {base, repo} = repo_with_remote()
      root = Path.join(base, "worktrees")
      File.mkdir_p!(root)
      path = worktree(repo, "shep/3", root)
      File.write!(Path.join(path, "local.txt"), "unpushed\n")
      git!(path, ["add", "."])
      git!(path, ["commit", "-qm", "local only"])

      assert %{decision: :unpushed} = Tidy.classify(path)
    end

    test "a worktree a live task owns is left alone even when reclaimable" do
      {base, repo} = repo_with_remote()
      root = Path.join(base, "worktrees")
      File.mkdir_p!(root)
      path = worktree(repo, "shep/4", root)
      git!(path, ["push", "-q", "origin", "shep/4"])
      git!(path, ["fetch", "-q", "origin"])

      busy = MapSet.new([Path.expand(path)])
      assert %{decision: :busy} = Tidy.classify(path, busy)
    end

    # Flocks can share a worktree root; `git worktree remove` only works
    # from the clone that owns the worktree, so another clone's is left be.
    test "a worktree owned by another clone is reported, not reclaimed" do
      {base, repo} = repo_with_remote()
      root = Path.join(base, "worktrees")
      File.mkdir_p!(root)
      path = worktree(repo, "shep/5", root)
      git!(path, ["push", "-q", "origin", "shep/5"])
      git!(path, ["fetch", "-q", "origin"])

      {_other_base, other_repo} = repo_with_remote()

      assert %{decision: :foreign} = Tidy.classify(path, MapSet.new(), common_dir(other_repo))
      # Owned by the clone that made it, so that daemon still reclaims it.
      assert %{decision: :reap} = Tidy.classify(path, MapSet.new(), common_dir(repo))
    end

    test "a directory that is not a worktree is reported, not reclaimed" do
      dir = scratch()
      assert %{decision: :unreadable} = Tidy.classify(dir)
    end
  end

  describe "survey/2" do
    test "classifies every worktree under the root" do
      {base, repo} = repo_with_remote()
      root = Path.join(base, "worktrees")
      File.mkdir_p!(root)

      pushed = worktree(repo, "shep/10", root)
      git!(pushed, ["push", "-q", "origin", "shep/10"])
      git!(pushed, ["fetch", "-q", "origin"])

      dirty = worktree(repo, "shep/11", root)
      File.write!(Path.join(dirty, "x.txt"), "x")

      config = %{"workspace" => %{"root" => root, "repo" => repo}}
      by_branch = Map.new(Tidy.survey(config), &{&1.branch, &1.decision})

      assert by_branch["shep/10"] == :reap
      assert by_branch["shep/11"] == :dirty
    end

    test "an absent root yields nothing rather than raising" do
      assert [] == Tidy.survey(%{"workspace" => %{"root" => "/nonexistent/root"}})
    end
  end
end
