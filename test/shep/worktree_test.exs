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
      root =
        Path.join(System.tmp_dir!(), "shep_stale_test_#{System.unique_integer([:positive])}")

      branch = "test-stale-#{System.unique_integer([:positive])}"
      path = Path.join(root, Worktree.sanitize_branch_for_test(branch))

      File.mkdir_p!(path)
      assert File.dir?(path), "precondition: stale directory exists"

      result = Worktree.create(branch, "main", root)

      case result do
        {:ok, created_path} ->
          assert created_path == path

        {:error, msg} ->
          refute String.contains?(msg, "already exists"),
                 "create must not fail with 'already exists' when stale dir is present: #{msg}"
      end

      File.rm_rf!(root)
    end

    test "sanitize_branch replaces non-alphanumeric chars but keeps hyphens" do
      assert "feature_foo-bar" == Worktree.sanitize_branch_for_test("feature/foo-bar")
      assert "no__slashes" == Worktree.sanitize_branch_for_test("no//slashes")
      assert "leading" == Worktree.sanitize_branch_for_test("__leading")
      assert "shep_49" == Worktree.sanitize_branch_for_test("shep/49")
    end
  end
end
