defmodule Shep.AgentRunner.PRDemoTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner.PR

  describe "demo tasks" do
    test "never push or create a PR, even on a clean Complete" do
      task = %Shep.Task{id: "demo-t", branch: "shep/demo-t", prompt: "x", demo: true}
      completion = %Shep.Completion.Complete{summary: "done"}

      assert :none == PR.create(completion, task, "/nonexistent", %{})
    end
  end
end

defmodule Shep.AgentRunner.PRCreateTest do
  # Installs the :gh_runner app env, so no concurrent cases.
  use ExUnit.Case, async: false

  alias Shep.AgentRunner.PR
  alias Shep.Completion.Complete

  setup do
    start_supervised!({Shep.Tracker.Memory, tasks: []})
    Application.put_env(:shep, :tracker_adapter, Shep.Tracker.Memory)

    on_exit(fn ->
      Application.delete_env(:shep, :tracker_adapter)
      Application.delete_env(:shep, :gh_runner)
    end)

    :ok
  end

  defp clean_committed_worktree(branch) do
    n = System.unique_integer([:positive])
    bare = Path.join(System.tmp_dir!(), "shep_pr_bare_#{n}.git")
    wt = Path.join(System.tmp_dir!(), "shep_pr_wt_#{n}")
    File.mkdir_p!(wt)

    on_exit(fn ->
      File.rm_rf!(bare)
      File.rm_rf!(wt)
    end)

    {_, 0} = System.cmd("git", ["init", "-q", "--bare", bare])
    {_, 0} = System.cmd("git", ["-C", wt, "init", "-q", "-b", branch])
    {_, 0} = System.cmd("git", ["-C", wt, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", wt, "config", "user.name", "Test"])
    {_, 0} = System.cmd("git", ["-C", wt, "commit", "-q", "--allow-empty", "-m", "work"])
    {_, 0} = System.cmd("git", ["-C", wt, "remote", "add", "origin", bare])
    wt
  end

  defp config, do: %{"tracker" => %{"repo" => "org/repo"}, "staging" => %{"pr_target" => "main"}}

  test "a missing PR label never sinks the PR creation" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn
      ["pr", "create" | _] = args ->
        send(test_pid, {:gh, args})
        {:ok, "https://github.com/org/repo/pull/9"}

      ["pr", "edit" | _] = args ->
        send(test_pid, {:gh, args})
        {:error, "could not add label: 'agent: claude-code' not found"}

      ["pr", "comment" | _] = args ->
        send(test_pid, {:gh, args})
        {:ok, ""}
    end)

    wt = clean_committed_worktree("shep/pr-1")
    task = %Shep.Task{id: "pr-1", branch: "shep/pr-1", prompt: "p"}

    assert {:ok, "https://github.com/org/repo/pull/9"} =
             PR.create(%Complete{summary: "did it"}, task, wt, config())

    assert_received {:gh, ["pr", "create" | create_args]}
    refute "--label" in create_args
    assert_received {:gh, ["pr", "edit" | edit_args]}
    assert "agent: claude-code" == List.last(edit_args)
    assert "pr-created" == Shep.Tracker.Memory.get_status("pr-1")
  end

  test "signs the PR by default with a Herded by Shep comment" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn
      ["pr", "create" | _] -> {:ok, "https://github.com/org/repo/pull/11"}
      ["pr", "edit" | _] -> {:ok, ""}
      ["pr", "comment" | _] = args -> send(test_pid, {:gh, args}) && {:ok, ""}
    end)

    wt = clean_committed_worktree("shep/pr-3")
    task = %Shep.Task{id: "pr-3", branch: "shep/pr-3", prompt: "p"}

    assert {:ok, url} = PR.create(%Complete{summary: "did it"}, task, wt, config())

    assert_received {:gh, ["pr", "comment", ^url, "--repo", "org/repo", "--body", body]}
    assert body =~ "Herded by Shep"
  end

  test "pr.sign false skips the signature comment entirely" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn
      ["pr", "create" | _] -> {:ok, "https://github.com/org/repo/pull/12"}
      ["pr", "edit" | _] -> {:ok, ""}
      ["pr", "comment" | _] = args -> send(test_pid, {:comment, args}) && {:ok, ""}
    end)

    wt = clean_committed_worktree("shep/pr-4")
    task = %Shep.Task{id: "pr-4", branch: "shep/pr-4", prompt: "p"}
    cfg = put_in(config(), ["pr"], %{"sign" => false})

    assert {:ok, _url} = PR.create(%Complete{summary: "did it"}, task, wt, cfg)

    refute_received {:comment, _}
  end

  test "a failed signature comment never sinks the PR creation" do
    Application.put_env(:shep, :gh_runner, fn
      ["pr", "create" | _] -> {:ok, "https://github.com/org/repo/pull/13"}
      ["pr", "edit" | _] -> {:ok, ""}
      ["pr", "comment" | _] -> {:error, "gh: comment failed"}
    end)

    wt = clean_committed_worktree("shep/pr-5")
    task = %Shep.Task{id: "pr-5", branch: "shep/pr-5", prompt: "p"}

    assert {:ok, "https://github.com/org/repo/pull/13"} =
             PR.create(%Complete{summary: "did it"}, task, wt, config())

    assert "pr-created" == Shep.Tracker.Memory.get_status("pr-5")
  end

  test "no_merge tasks request the shep:no-merge label" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn
      ["pr", "create" | _] -> {:ok, "https://github.com/org/repo/pull/10"}
      ["pr", "edit" | _] = args -> send(test_pid, {:gh, args}) && {:ok, ""}
      ["pr", "comment" | _] -> {:ok, ""}
    end)

    wt = clean_committed_worktree("shep/pr-2")
    task = %Shep.Task{id: "pr-2", branch: "shep/pr-2", prompt: "p", no_merge: true}

    assert {:ok, _url} = PR.create(%Complete{summary: "did it"}, task, wt, config())

    assert_received {:gh, edit_args}
    assert "shep:no-merge" == List.last(edit_args)
  end
end
