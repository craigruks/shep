defmodule Shep.WorktreeTest do
  use ExUnit.Case

  alias Shep.Worktree

  describe "list/1" do
    test "returns empty list for nonexistent directory" do
      assert [] == Worktree.list("/tmp/shep_test_nonexistent_#{System.unique_integer()}")
    end

    test "returns directories in root" do
      root = Path.join(System.tmp_dir!(), "shep_wt_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "branch_a"))
      File.mkdir_p!(Path.join(root, "branch_b"))
      File.write!(Path.join(root, "not_a_dir.txt"), "hi")

      dirs = Worktree.list(root)
      assert length(dirs) == 2
      assert Enum.all?(dirs, &File.dir?/1)

      File.rm_rf!(root)
    end
  end

  describe "has_uncommitted_changes?/1" do
    test "returns true for non-git directory" do
      assert Worktree.has_uncommitted_changes?(System.tmp_dir!())
    end
  end

  describe "prune/0" do
    test "runs without error" do
      assert :ok == Worktree.prune()
    end
  end

  describe "create/3 handles stale state" do
    test "cleanup_stale removes leftover directory before creating worktree" do
      n = System.unique_integer([:positive])
      repo = Path.join(System.tmp_dir!(), "shep_stale_repo_#{n}")
      root = Path.join(System.tmp_dir!(), "shep_stale_root_#{n}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf!(repo) && File.rm_rf!(root) end)

      {_, 0} = System.cmd("git", ["-C", repo, "init", "-q", "-b", "main"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
      File.write!(Path.join(repo, "flock.txt"), "sheep")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-qm", "init"])

      branch = "test-stale-#{n}"
      path = Path.expand(Path.join(root, Worktree.sanitize_branch_for_test(branch)))

      File.mkdir_p!(path)
      assert File.dir?(path), "precondition: stale directory exists"

      result = Worktree.create(branch, "main", root, repo)

      case result do
        {:ok, created_path} ->
          assert created_path == path

        {:error, msg} ->
          refute String.contains?(msg, "already exists"),
                 "create must not fail with 'already exists' when stale dir is present: #{msg}"
      end
    end

    test "sanitize_branch replaces non-alphanumeric chars but keeps hyphens" do
      assert "feature_foo-bar" == Worktree.sanitize_branch_for_test("feature/foo-bar")
      assert "no__slashes" == Worktree.sanitize_branch_for_test("no//slashes")
      assert "leading" == Worktree.sanitize_branch_for_test("__leading")
      assert "shep_49" == Worktree.sanitize_branch_for_test("shep/49")
    end
  end
end

defmodule Shep.WorktreeRepoParamTest do
  use ExUnit.Case, async: false

  test "cuts and removes worktrees from a repo other than cwd" do
    n = System.unique_integer([:positive])
    repo = Path.join(System.tmp_dir!(), "shep_ext_repo_#{n}")
    root = Path.join(System.tmp_dir!(), "shep_ext_root_#{n}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) && File.rm_rf!(root) end)

    {_, 0} = System.cmd("git", ["-C", repo, "init", "-q", "-b", "main"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
    File.write!(Path.join(repo, "flock.txt"), "sheep")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-qm", "init"])

    assert {:ok, path} = Shep.Worktree.create("shep/ext-#{n}", "main", root, repo)
    assert File.exists?(Path.join(path, "flock.txt"))
    assert :ok = Shep.Worktree.remove(path, repo)
    refute File.dir?(path)
  end
end

defmodule Shep.WorktreeFreshBaseTest do
  use ExUnit.Case, async: true

  # The clone Shep cuts from is long-lived and nothing else refreshes it,
  # so `create` fetches first — including when several cuts land at once.
  setup do
    n = System.unique_integer([:positive])
    tmp = System.tmp_dir!()
    origin = Path.join(tmp, "shep_fresh_origin_#{n}")
    clone = Path.join(tmp, "shep_fresh_clone_#{n}")
    seed = Path.join(tmp, "shep_fresh_seed_#{n}")
    root = Path.join(tmp, "shep_fresh_root_#{n}")

    on_exit(fn -> Enum.each([origin, clone, seed, root], &File.rm_rf!/1) end)

    git!(["init", "-q", "--bare", "-b", "main", origin])
    File.mkdir_p!(seed)
    git!(["-C", seed, "init", "-q", "-b", "main"])
    git!(["-C", seed, "config", "user.email", "test@example.com"])
    git!(["-C", seed, "config", "user.name", "Test"])
    git!(["-C", seed, "remote", "add", "origin", origin])
    commit(seed, "sheep")
    git!(["-C", seed, "push", "-q", "origin", "main"])
    git!(["clone", "-q", origin, clone])

    %{origin: origin, clone: clone, seed: seed, root: root, n: n}
  end

  test "cuts from the remote tip, not the clone's stale copy", ctx do
    advance(ctx.seed, "more sheep")

    assert {:ok, path} = Shep.Worktree.create("shep/fresh-#{ctx.n}", "main", ctx.root, ctx.clone)
    assert File.read!(Path.join(path, "flock.txt")) == "more sheep"
  end

  test "concurrent cuts all land on the remote tip", ctx do
    advance(ctx.seed, "more sheep")

    results =
      1..4
      |> Task.async_stream(
        fn i -> Shep.Worktree.create("shep/race-#{ctx.n}-#{i}", "main", ctx.root, ctx.clone) end,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    for result <- results do
      assert {:ok, path} = result
      assert File.read!(Path.join(path, "flock.txt")) == "more sheep"
    end
  end

  test "a failed fetch fails the cut instead of using a stale base", ctx do
    File.rm_rf!(ctx.origin)
    branch = "shep/nofetch-#{ctx.n}"

    assert {:error, reason} = Shep.Worktree.create(branch, "main", ctx.root, ctx.clone)
    assert reason =~ "git fetch"
    refute File.dir?(Shep.Worktree.path_for(branch, ctx.root))
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end

  defp commit(repo, content) do
    File.write!(Path.join(repo, "flock.txt"), content)
    git!(["-C", repo, "add", "."])
    git!(["-C", repo, "commit", "-qm", content])
  end

  defp advance(seed, content) do
    commit(seed, content)
    git!(["-C", seed, "push", "-q", "origin", "main"])
  end
end
