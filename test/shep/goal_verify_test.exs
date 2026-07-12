defmodule Shep.GoalVerifyLoopTest do
  use ExUnit.Case, async: true

  alias Shep.Completion.{Complete, Failed}

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
    run_turn = fn prompt -> Shep.AgentRunner.fix_turn(prompt, dir, task, config, opid) end
    Shep.Goal.verify_loop(final, task, dir, config, opid, run_turn)
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

  test "exhausted fix attempts yield Failed with the verify tail" do
    dir = tmp_dir()
    agent = stub_agent(dir, "echo still broken")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v3", branch: "b", prompt: "p"}

    assert %Failed{reason: reason, recoverable: false} =
             verify(final, task, dir, config("echo nope; false", agent, 2))

    assert reason =~ "verify failed after 2 fix attempts"
    assert reason =~ "nope"
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
