defmodule Shep.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Shep.Orchestrator

  defmodule HangingTracker do
    @moduledoc """
    Tracker whose `claim/1` never returns. Dispatched agent tasks block
    at the network boundary, so they deterministically stay in `running`
    until the test kills them — and never reach gh, git, or an agent CLI.
    """
    @behaviour Shep.Tracker

    @impl true
    def fetch_candidates, do: {:ok, []}

    @impl true
    def claim(_task_id), do: Process.sleep(:infinity)

    @impl true
    def update_status(_task_id, _status), do: :ok

    @impl true
    def add_comment(_task_id, _body), do: :ok
  end

  setup do
    Application.put_env(:shep, :tracker_adapter, HangingTracker)
    on_exit(fn -> Application.delete_env(:shep, :tracker_adapter) end)
    :ok
  end

  # Submits a task that hangs in HangingTracker.claim/1 and registers
  # cleanup, so no test leaks a running task (and a concurrency slot)
  # into its siblings.
  defp submit_hanging_task(prefix) do
    task = %Shep.Task{
      id: "#{prefix}-#{System.unique_integer([:positive])}",
      branch: "test/#{prefix}",
      prompt: "echo hello"
    }

    on_exit(fn -> Orchestrator.kill(task.id) end)
    {Orchestrator.submit(task), task}
  end

  describe "snapshot/0" do
    test "returns state from ETS when orchestrator is running" do
      snapshot = Orchestrator.snapshot()
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :running)
      assert Map.has_key?(snapshot, :claimed)
    end
  end

  describe "submit/1" do
    test "accepts a valid task and starts running it" do
      {result, task} = submit_hanging_task("test-submit")

      assert :ok = result
      assert Map.has_key?(Orchestrator.snapshot().running, task.id)
    end
  end

  describe "kill/1" do
    test "returns error for a task that is not running" do
      assert {:error, "task not running"} = Orchestrator.kill("no-such-task")
    end

    test "kills a running task without scheduling a retry" do
      {:ok, task} = submit_hanging_task("test-kill")

      assert Map.has_key?(Orchestrator.snapshot().running, task.id),
             "task must be dispatched, not queued: another test leaked a running task"

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
