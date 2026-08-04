defmodule Shep.Orchestrator.PauseKillTest do
  # Spawns real agent processes through the real orchestrator, so it must
  # not run concurrently with other cases.
  use ExUnit.Case, async: false

  alias Shep.AgentRunner.Exec

  @moduletag :capture_log

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "shep_pause_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # An agent that reports its own pid and then keeps running, exactly the
  # shape that survived a pause in #63.
  defp sleeper_agent(dir) do
    path = Path.join(dir, "agent.sh")
    File.write!(path, "#!/bin/sh\necho $$\nexec sleep 60\n")
    File.chmod!(path, 0o755)
    path
  end

  defp run_agent(dir) do
    exe = sleeper_agent(dir)
    task = %Shep.Task{id: "pause-#{System.unique_integer([:positive])}", branch: "b", prompt: "p"}
    test = self()

    runner =
      spawn(fn ->
        send(test, {:result, Exec.run(exe, [], dir, task, test, 30_000)})
      end)

    # The agent announces its pid on its first line.
    os_pid =
      receive do
        {:agent_output, _id, line} -> line |> String.trim() |> String.to_integer()
      after
        10_000 -> flunk("agent never started")
      end

    {runner, os_pid}
  end

  describe "terminate/2" do
    test "stops an agent that ignores a closed Port", %{} do
      dir = tmp_dir()
      {runner, os_pid} = run_agent(dir)

      refute Exec.gone?(os_pid), "agent should be running before termination"

      # Killing the Elixir process alone is what #63 relied on, and is
      # exactly what leaves the agent behind.
      Process.exit(runner, :kill)
      Process.sleep(200)
      refute Exec.gone?(os_pid), "killing the Task must not be assumed to stop the agent"

      assert :ok = Exec.terminate(os_pid)
      assert Exec.gone?(os_pid), "the agent process must be gone after terminate/2"
    end

    test "is idempotent and safe on a process that has already exited" do
      dir = tmp_dir()
      {_runner, os_pid} = run_agent(dir)

      assert :ok = Exec.terminate(os_pid)
      assert :ok = Exec.terminate(os_pid)
      assert :ok = Exec.terminate(nil)
      assert Exec.gone?(os_pid)
    end

    test "escalates to SIGKILL when the agent ignores SIGTERM" do
      dir = tmp_dir()
      path = Path.join(dir, "stubborn.sh")
      File.write!(path, "#!/bin/sh\ntrap '' TERM\necho $$\nwhile true; do sleep 1; done\n")
      File.chmod!(path, 0o755)

      task = %Shep.Task{id: "stubborn", branch: "b", prompt: "p"}
      test = self()
      spawn(fn -> Exec.run(path, [], dir, task, test, 30_000) end)

      os_pid =
        receive do
          {:agent_output, _id, line} -> line |> String.trim() |> String.to_integer()
        after
          10_000 -> flunk("stubborn agent never started")
        end

      assert :ok = Exec.terminate(os_pid, 500)
      assert Exec.gone?(os_pid), "a SIGTERM-ignoring agent must still be killed"
    end
  end

  describe "the runner reports its agent's pid" do
    test "so a pause or kill outside the Task can signal it" do
      dir = tmp_dir()
      {_runner, os_pid} = run_agent(dir)

      # Sent through the same channel as worktree_path and session_name.
      assert_receive {:agent_meta, _id, %{os_pid: reported}}, 5_000
      assert reported == os_pid

      Exec.terminate(os_pid)
    end
  end
end
