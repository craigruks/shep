defmodule Shep.GoalCILoopTest do
  # Installs global adapters (:ci_watch_adapter, :tracker_adapter),
  # so this module must not run concurrently with other cases.
  use ExUnit.Case, async: false

  alias Shep.CIWatchStub
  alias Shep.Completion.{Complete, Failed}
  alias Shep.Tracker.Memory

  @pr_url "https://github.com/org/repo/pull/7"

  setup do
    start_supervised!({Memory, tasks: []})
    Application.put_env(:shep, :tracker_adapter, Memory)

    on_exit(fn ->
      Application.delete_env(:shep, :tracker_adapter)
      CIWatchStub.uninstall()
    end)

    :ok
  end

  # Drives Goal.ci_loop with the real fix-turn capability injected,
  # exactly the wiring AgentRunner.run/3 performs in production.
  defp ci(final, pr_url, task, wt, config) do
    opid = self()
    run_turn = fn prompt -> Shep.AgentRunner.fix_turn(prompt, wt, task, config, opid) end
    Shep.Goal.ci_loop(final, pr_url, task, wt, config, opid, run_turn)
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp stub_agent(dir, body) do
    path = Path.join(dir, "stub_agent.sh")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  defp config(agent_cmd, ci_fixes) do
    %{
      "tracker" => %{"repo" => "org/repo"},
      "goal" => %{"ci_fixes" => ci_fixes},
      "agent" => %{"command" => agent_cmd}
    }
  end

  # A worktree on `branch` whose origin is a local bare repo, so
  # push_branch/2 succeeds without touching the network.
  defp git_worktree_with_remote(branch) do
    n = System.unique_integer([:positive])
    bare = Path.join(System.tmp_dir!(), "shep_ci_bare_#{n}.git")
    wt = Path.join(System.tmp_dir!(), "shep_ci_wt_#{n}")
    File.mkdir_p!(wt)

    on_exit(fn ->
      File.rm_rf!(bare)
      File.rm_rf!(wt)
    end)

    {_, 0} = System.cmd("git", ["init", "-q", "--bare", bare])
    {_, 0} = System.cmd("git", ["-C", wt, "init", "-q", "-b", branch])
    {_, 0} = System.cmd("git", ["-C", wt, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", wt, "config", "user.name", "Test"])
    {_, 0} = System.cmd("git", ["-C", wt, "commit", "-q", "--allow-empty", "-m", "init"])
    {_, 0} = System.cmd("git", ["-C", wt, "remote", "add", "origin", bare])
    {wt, bare}
  end

  test "green CI on the first watch passes the completion through, no fix turns" do
    CIWatchStub.install([:passed])
    dir = tmp_dir("shep_ci_green")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "ci-1", branch: "shep/ci-1", prompt: "p"}

    assert ^final =
             ci(
               final,
               @pr_url,
               task,
               dir,
               config("unused", 2)
             )

    assert "in-review" == Memory.get_status("ci-1")
  end

  test "red then green: exactly one fix turn runs, the branch is pushed, verdict passes" do
    CIWatchStub.install([{:failed, "Quality"}, :passed], "quality gate exploded")
    {wt, bare} = git_worktree_with_remote("shep/ci-2")

    agent =
      stub_agent(wt, ~S(printf '%s\n' "$@" > fix_args.txt) <> "\ntouch ci_fix.marker\necho fixed")

    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "ci-2", branch: "shep/ci-2", prompt: "p"}

    assert ^final =
             ci(final, @pr_url, task, wt, config(agent, 2))

    assert File.exists?(Path.join(wt, "ci_fix.marker"))
    assert File.read!(Path.join(wt, "fix_args.txt")) =~ "quality gate exploded"
    assert {_, 0} = System.cmd("git", ["-C", bare, "rev-parse", "--verify", "refs/heads/shep/ci-2"])
    assert "in-review" == Memory.get_status("ci-2")
    assert_received {:agent_output, "ci-2", _line}
  end

  test "red CI exhausting ci_fixes returns Failed and exercises the give-up path" do
    CIWatchStub.install([{:failed, "Quality"}, {:failed, "Quality"}])
    {wt, _bare} = git_worktree_with_remote("shep/ci-3")
    agent = stub_agent(wt, "echo tried a fix")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "ci-3", branch: "shep/ci-3", prompt: "p"}

    assert %Failed{reason: reason, recoverable: false} =
             ci(final, @pr_url, task, wt, config(agent, 1))

    assert reason =~ "CI failed after 1 fix attempts"
    assert reason =~ "Quality"
    assert "failed" == Memory.get_status("ci-3")
    assert ["Goal not reached: " <> _] = Memory.get_comments("ci-3")
  end

  test "codex tasks skip fix turns and fail straight through on red CI" do
    CIWatchStub.install([{:failed, "Build"}])
    dir = tmp_dir("shep_ci_codex")
    agent = stub_agent(dir, "touch ci_fix.marker")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "ci-4", branch: "shep/ci-4", prompt: "p", agent: :codex}

    assert %Failed{reason: reason, recoverable: false} =
             ci(final, @pr_url, task, dir, config(agent, 2))

    assert reason =~ "CI failed after 0 fix attempts"
    refute File.exists?(Path.join(dir, "ci_fix.marker"))
    assert "failed" == Memory.get_status("ci-4")
  end

  test "a failed push during a CI fix gives up with the push error" do
    CIWatchStub.install([{:failed, "Quality"}])
    dir = tmp_dir("shep_ci_pushfail")
    {_, 0} = System.cmd("git", ["-C", dir, "init", "-q", "-b", "shep/ci-5"])
    agent = stub_agent(dir, "echo tried a fix")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "ci-5", branch: "shep/ci-5", prompt: "p"}

    assert %Failed{reason: reason, recoverable: false} =
             ci(final, @pr_url, task, dir, config(agent, 2))

    assert reason =~ "push failed during CI fix"
    assert "failed" == Memory.get_status("ci-5")
  end

  test "no-merge tasks skip the CI watch entirely" do
    # An empty script means any watch/3 call would crash the stub.
    CIWatchStub.install([])
    dir = tmp_dir("shep_ci_nomerge")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "ci-6", branch: "shep/ci-6", prompt: "p", no_merge: true}

    assert ^final =
             ci(
               final,
               @pr_url,
               task,
               dir,
               config("unused", 2)
             )

    assert nil == Memory.get_status("ci-6")
  end
end
