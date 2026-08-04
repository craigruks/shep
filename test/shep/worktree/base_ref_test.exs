defmodule Shep.Worktree.BaseRefTest do
  use ExUnit.Case, async: true

  alias Shep.Worktree.BaseRef

  setup do
    n = System.unique_integer([:positive])
    tmp = System.tmp_dir!()
    origin = Path.join(tmp, "shep_baseref_origin_#{n}")
    clone = Path.join(tmp, "shep_baseref_clone_#{n}")
    seed = Path.join(tmp, "shep_baseref_seed_#{n}")
    plain = Path.join(tmp, "shep_baseref_plain_#{n}")

    on_exit(fn -> Enum.each([origin, clone, seed, plain], &File.rm_rf!/1) end)

    git!(["init", "-q", "--bare", "-b", "main", origin])
    init_repo(seed)
    git!(["-C", seed, "remote", "add", "origin", origin])
    commit(seed, "one")
    git!(["-C", seed, "push", "-q", "origin", "main"])
    git!(["clone", "-q", origin, clone])
    config_identity(clone)

    init_repo(plain)
    commit(plain, "one")

    %{origin: origin, clone: clone, seed: seed, plain: plain}
  end

  describe "resolve/2 without a remote-tracking ref" do
    test "returns the base branch untouched", %{plain: plain} do
      # The demo cuts from the current local branch; there is nothing to fetch.
      assert {:ok, "main"} == BaseRef.resolve(plain, "main")
    end

    test "returns a branch that exists on no remote", %{clone: clone} do
      assert {:ok, "nope"} == BaseRef.resolve(clone, "nope")
    end
  end

  describe "resolve/2 with a remote-tracking ref" do
    test "fetches, and resolves to the remote ref now at the remote tip", ctx do
      advance(ctx.seed, "two")
      remote_tip = rev(ctx.seed, "HEAD")

      assert rev(ctx.clone, "origin/main") != remote_tip, "precondition: clone is stale"
      assert {:ok, "origin/main"} == BaseRef.resolve(ctx.clone, "main")
      assert rev(ctx.clone, "origin/main") == remote_tip
    end

    test "accepts a base branch already written as a remote ref", ctx do
      advance(ctx.seed, "two")

      assert {:ok, "origin/main"} == BaseRef.resolve(ctx.clone, "origin/main")
      assert rev(ctx.clone, "origin/main") == rev(ctx.seed, "HEAD")
    end

    test "leaves the stale local branch alone", ctx do
      stale = rev(ctx.clone, "main")
      advance(ctx.seed, "two")

      assert {:ok, "origin/main"} == BaseRef.resolve(ctx.clone, "main")
      assert rev(ctx.clone, "main") == stale
    end

    test "errors instead of proceeding when the fetch fails", ctx do
      File.rm_rf!(ctx.origin)

      assert {:error, reason} = BaseRef.resolve(ctx.clone, "main")
      assert reason =~ "git fetch origin main failed"
    end
  end

  describe "concurrent resolves" do
    test "serialize: every caller lands on the fresh remote tip", ctx do
      advance(ctx.seed, "two")
      remote_tip = rev(ctx.seed, "HEAD")

      results =
        1..6
        |> Task.async_stream(fn _ -> BaseRef.resolve(ctx.clone, "main") end, timeout: 60_000)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == {:ok, "origin/main"})),
             "a lost fetch race must not surface as a stale base: #{inspect(results)}"

      assert rev(ctx.clone, "origin/main") == remote_tip
    end
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end

  defp init_repo(path) do
    File.mkdir_p!(path)
    git!(["-C", path, "init", "-q", "-b", "main"])
    config_identity(path)
  end

  defp config_identity(path) do
    git!(["-C", path, "config", "user.email", "test@example.com"])
    git!(["-C", path, "config", "user.name", "Test"])
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

  defp rev(repo, ref) do
    ["-C", repo, "rev-parse", ref] |> git!() |> String.trim()
  end
end
