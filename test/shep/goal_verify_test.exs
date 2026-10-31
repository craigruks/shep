defmodule Shep.GoalVerifyLoopTest do
  # A give-up posts to the tracker, so the Memory adapter is installed
  # globally and this module must not run concurrently with others.
  use ExUnit.Case, async: false

  alias Shep.Completion.{Complete, Failed}
  alias Shep.Tracker.Memory

  @fake_token "ghp_" <> String.duplicate("A1b2C3d4", 5)

  setup do
    start_supervised!({Memory, tasks: []})
    Application.put_env(:shep, :tracker_adapter, Memory)
    on_exit(fn -> Application.delete_env(:shep, :tracker_adapter) end)
    :ok
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "shep_verify_#{System.unique_integer([:positive])}")
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

  defp config(verify, agent_cmd, fixes) do
    %{
      "goal" => %{"verify" => verify, "verify_fixes" => fixes},
      "agent" => %{"command" => agent_cmd}
    }
  end

  # Drives Goal.verify_loop with the real fix-turn capability injected,
  # exactly the wiring AgentRunner.run/3 performs in production.
  defp verify(final, task, dir, config) do
    opid = self()
    ws = Shep.Workspace.local(dir)
    run_turn = fn prompt -> Shep.AgentRunner.fix_turn(prompt, ws, task, config, opid) end
    Shep.Goal.verify_loop(final, task, ws, config, opid, run_turn)
  end

  test "green verify on the first try returns the completion unchanged" do
    dir = tmp_dir()
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v1", branch: "b", prompt: "p"}

    assert ^final = verify(final, task, dir, config("true", "unused", 2))
  end

  test "red verify dispatches a fix turn, then re-verifies green" do
    dir = tmp_dir()
    agent = stub_agent(dir, "touch fixed.marker\necho applied a fix")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v2", branch: "b", prompt: "p"}

    result = verify(final, task, dir, config("test -f fixed.marker", agent, 2))

    assert %Complete{} = result
    assert File.exists?(Path.join(dir, "fixed.marker"))
    assert_received {:agent_output, "v2", _line}
  end

  test "exhausted fix attempts fail the task: shep:failed plus the redacted verify tail" do
    dir = tmp_dir()
    agent = stub_agent(dir, "echo still broken")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v3", branch: "b", prompt: "p"}
    verify_cmd = "echo 'assertion nope'; echo 'GITHUB_TOKEN=#{@fake_token}'; false"

    assert %Failed{reason: reason, recoverable: false} =
             verify(final, task, dir, config(verify_cmd, agent, 2))

    assert reason =~ "verify failed after 2 fix attempts"
    assert "failed" == Memory.get_status("v3")
    assert [comment] = Memory.get_comments("v3")
    assert comment =~ "Goal not reached: verify failed after 2 fix attempts"
    assert comment =~ "<details>"
    assert comment =~ "assertion nope"
    assert comment =~ "GITHUB_TOKEN=[REDACTED]"
    refute comment =~ @fake_token
  end

  test "an agent that gives up during a verify fix fails the task with its output" do
    dir = tmp_dir()

    agent =
      stub_agent(
        dir,
        ~S(echo 'cannot fix this'; echo '<completion>{"type":"failed","reason":"flaky env","recoverable":false}</completion>')
      )

    task = %Shep.Task{id: "v7", branch: "b", prompt: "p"}

    assert %Failed{reason: reason} =
             verify(%Complete{summary: "done"}, task, dir, config("false", agent, 2))

    assert reason =~ "agent gave up during verify fix 1/2: flaky env"
    assert "failed" == Memory.get_status("v7")
    assert [comment] = Memory.get_comments("v7")
    assert comment =~ "cannot fix this"
  end

  test "demo tasks skip the verify loop entirely" do
    dir = tmp_dir()
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v4", branch: "b", prompt: "p", demo: true}

    assert ^final = verify(final, task, dir, config("false", "unused", 2))
  end

  test "codex tasks skip the verify loop (fix turns are claude-only)" do
    dir = tmp_dir()
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v5", branch: "b", prompt: "p", agent: :codex}

    assert ^final = verify(final, task, dir, config("false", "unused", 2))
  end

  test "a Failed completion passes through without running verify" do
    dir = tmp_dir()
    final = %Failed{reason: "agent gave up", recoverable: false}
    task = %Shep.Task{id: "v6", branch: "b", prompt: "p"}

    assert ^final = verify(final, task, dir, config("false", "unused", 2))
  end
end
