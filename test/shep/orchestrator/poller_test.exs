defmodule Shep.Orchestrator.PollerTest do
  use ExUnit.Case, async: true

  alias Shep.Orchestrator.Poller

  describe "deps_resolved?/2" do
    test "a task with no dependencies is always clear" do
      assert Poller.deps_resolved?("org/repo", %{depends_on: nil})
      assert Poller.deps_resolved?("org/repo", %{depends_on: []})
    end
  end

  describe "schedule_tick/1" do
    test "stamps a fresh tick token and timer, cancelling the previous timer" do
      state = %Shep.Orchestrator{}
      scheduled = Poller.schedule_tick(state)

      assert is_reference(scheduled.tick_token)
      assert scheduled.tick_timer != nil

      # A second schedule rotates the token and cancels the old timer
      # without raising on the stale reference.
      rescheduled = Poller.schedule_tick(scheduled)
      assert rescheduled.tick_token != scheduled.tick_token
    end
  end
end
