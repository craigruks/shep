defmodule Shep.OrchestratorTest do
  use ExUnit.Case

  alias Shep.Orchestrator

  describe "snapshot/0" do
    test "returns state from ETS when orchestrator is running" do
      snapshot = Orchestrator.snapshot()
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :running)
      assert Map.has_key?(snapshot, :claimed)
    end
  end

  describe "submit/1" do
    test "accepts a valid task" do
      task = %Shep.Task{
        id: "test-submit-#{System.unique_integer([:positive])}",
        branch: "test/submit",
        prompt: "echo hello"
      }

      assert :ok = Orchestrator.submit(task)
    end
  end

  describe "kill/1" do
    test "returns error for a task that is not running" do
      assert {:error, "task not running"} = Orchestrator.kill("no-such-task")
    end

    test "kills a running task without scheduling a retry" do
      task = %Shep.Task{
        id: "test-kill-#{System.unique_integer([:positive])}",
        branch: "test/kill",
        prompt: "echo hello"
      }

      :ok = Orchestrator.submit(task)
      assert :ok = Orchestrator.kill(task.id)
      refute Map.has_key?(Orchestrator.snapshot().running, task.id)
      assert {:error, "task not running"} = Orchestrator.kill(task.id)
    end
  end

  describe "tick token lifecycle" do
    test "init stores tick_token so first tick fires" do
      state = :sys.get_state(Orchestrator)
      assert state.tick_token != nil, "tick_token must be set after init"
      assert state.tick_timer != nil, "tick_timer must be set after init"
    end

    test "tick messages with stale tokens are ignored" do
      stale_token = make_ref()
      send(Orchestrator, {:tick, stale_token})
      Process.sleep(50)
      snapshot = Orchestrator.snapshot()
      assert is_map(snapshot), "orchestrator still functional after stale tick"
    end

    test "schedule_tick returns state with new token" do
      state_before = :sys.get_state(Orchestrator)
      token_before = state_before.tick_token

      send(Orchestrator, {:tick, token_before})
      Process.sleep(100)

      state_after = :sys.get_state(Orchestrator)

      assert state_after.tick_token != token_before,
             "tick_token must change after each tick (was #{inspect(token_before)}, still #{inspect(state_after.tick_token)})"
    end
  end
end
