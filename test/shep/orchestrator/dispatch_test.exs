defmodule Shep.Orchestrator.DispatchTest do
  use ExUnit.Case, async: true

  alias Shep.Orchestrator.Dispatch

  defp task(id), do: %Shep.Task{id: id, branch: "shep/#{id}", prompt: "p"}

  defp entry(id), do: %{task: task(id), pid: self(), ref: make_ref()}

  defp crash(state, id, e) do
    state = %{state | running: Map.put(state.running, id, e)}
    Dispatch.handle_task_exit(id, e, {:badarg, []}, state)
  end

  describe "handle_task_exit/4 retry accounting" do
    test "a crash populates retry_attempts with attempt 1 and the base delay" do
      e = entry("t1")
      state = crash(%Shep.Orchestrator{}, "t1", e)

      assert %{attempt: 1, task: %Shep.Task{id: "t1"}, timer_ref: timer} =
               state.retry_attempts["t1"]

      assert state.running == %{}
      assert_in_delta Process.read_timer(timer), 10_000, 200
    end

    test "consecutive crashes increment the attempt and grow the delay" do
      e = entry("t2")
      s1 = crash(%Shep.Orchestrator{}, "t2", e)
      s2 = crash(s1, "t2", e)
      s3 = crash(s2, "t2", e)

      assert s2.retry_attempts["t2"].attempt == 2
      assert s3.retry_attempts["t2"].attempt == 3
      assert_in_delta Process.read_timer(s2.retry_attempts["t2"].timer_ref), 20_000, 200
      assert_in_delta Process.read_timer(s3.retry_attempts["t2"].timer_ref), 40_000, 200
    end

    test "the fourth crash exhausts retries and cleans the entry" do
      e = entry("t3")

      exhausted =
        %Shep.Orchestrator{}
        |> crash("t3", e)
        |> crash("t3", e)
        |> crash("t3", e)
        |> crash("t3", e)

      assert exhausted.retry_attempts == %{}
    end

    test "normal and shutdown exits clean any retry state" do
      e = entry("t4")
      crashed = crash(%Shep.Orchestrator{}, "t4", e)

      after_normal = Dispatch.handle_task_exit("t4", e, :normal, crashed)
      assert after_normal.retry_attempts == %{}

      crashed = crash(%Shep.Orchestrator{}, "t4", e)
      after_shutdown = Dispatch.handle_task_exit("t4", e, {:shutdown, :drain}, crashed)
      assert after_shutdown.retry_attempts == %{}
    end

    test "a crash while paused preserves the pause and schedules no retry" do
      e = entry("t5")

      state = %Shep.Orchestrator{
        running: %{"t5" => e},
        paused: %{"t5" => :paused_placeholder}
      }

      after_exit = Dispatch.handle_task_exit("t5", e, {:badarg, []}, state)
      assert after_exit.retry_attempts == %{}
      assert Map.has_key?(after_exit.paused, "t5")
      assert after_exit.running == %{}
    end
  end
end
