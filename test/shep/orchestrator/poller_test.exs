defmodule Shep.Orchestrator.PollerTest do
  use ExUnit.Case, async: true

  alias Shep.Orchestrator.Poller

  defp task(id), do: %Shep.Task{id: id, branch: "shep/#{id}", prompt: "p"}

  # A live agent process the watchdog can kill, plus a running entry addressed
  # by `token`. `quiet_ms` back-dates last_output_at so we can drive both cadences.
  defp running_state(id, token, quiet_ms, opts \\ []) do
    agent = spawn(fn -> Process.sleep(:infinity) end)
    now = System.monotonic_time(:millisecond)

    entry =
      %{
        pid: agent,
        ref: make_ref(),
        task: task(id),
        started_at: now,
        last_output_at: now - quiet_ms,
        watchdog_timer: nil,
        watchdog_token: token
      }
      |> Map.merge(Map.new(opts))

    {agent, %Shep.Orchestrator{running: %{id => entry}}}
  end

  describe "deps_resolved?/2" do
    test "a task with no dependencies is always clear" do
      assert Poller.deps_resolved?("org/repo", %{depends_on: nil})
      assert Poller.deps_resolved?("org/repo", %{depends_on: []})
    end
  end

  describe "watchdog_tick/3 recurring idle kill" do
    test "re-arms while fresh, then kills a task that goes idle after the first tick" do
      token = make_ref()
      {agent, state} = running_state("wd1", token, 1_000)
      ref = Process.monitor(agent)

      # Fresh: no kill, the loop re-arms with a rotated token and a live timer.
      s1 = Poller.watchdog_tick("wd1", token, state)
      assert Process.alive?(agent)
      new_token = s1.running["wd1"].watchdog_token
      assert new_token != token
      assert is_reference(s1.running["wd1"].watchdog_timer)

      # The agent now goes silent past the idle timeout. A tick on the *new*
      # token — the re-armed one — is what catches the stall the one-shot missed.
      idle_entry = %{
        s1.running["wd1"]
        | last_output_at: System.monotonic_time(:millisecond) - 700_000
      }

      s2 = %{s1 | running: %{"wd1" => idle_entry}}
      Poller.watchdog_tick("wd1", new_token, s2)

      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 1_000
    end

    test "a stale token is inert: no kill, no re-arm" do
      token = make_ref()
      {agent, state} = running_state("wd2", token, 700_000)

      returned = Poller.watchdog_tick("wd2", make_ref(), state)

      assert returned == state
      assert Process.alive?(agent)
    end
  end

  # The heartbeat's observable signal is the last_heartbeat_at stamp: it flips
  # from nil to an integer exactly when a gap heartbeat is emitted (the info
  # line rides the same branch). Asserting on it is hermetic where capturing an
  # info log under the suite's :warning level is not.
  describe "watchdog_tick/3 gap-triggered heartbeat" do
    test "a quiet stretch past the threshold stamps a single heartbeat" do
      token = make_ref()
      {_agent, state} = running_state("hb1", token, 34_000)

      new_state = Poller.watchdog_tick("hb1", token, state)

      assert is_integer(new_state.running["hb1"].last_heartbeat_at)
    end

    test "an actively streaming agent emits no heartbeat" do
      token = make_ref()
      {_agent, state} = running_state("hb2", token, 1_000)

      new_state = Poller.watchdog_tick("hb2", token, state)

      refute is_integer(new_state.running["hb2"][:last_heartbeat_at])
    end

    test "no second heartbeat until another quiet window elapses" do
      token = make_ref()
      recent = System.monotonic_time(:millisecond) - 1_000
      {_agent, state} = running_state("hb3", token, 34_000, last_heartbeat_at: recent)

      new_state = Poller.watchdog_tick("hb3", token, state)

      # Within the window: the prior stamp is preserved, no fresh heartbeat.
      assert new_state.running["hb3"].last_heartbeat_at == recent
    end
  end

  describe "cancel_watchdog/1 timer cleanup" do
    test "cancels a pending timer and tolerates an entry with none" do
      timer = Process.send_after(self(), :never, 100_000)

      assert Poller.cancel_watchdog(%{watchdog_timer: timer}) == :ok
      assert Process.read_timer(timer) == false
      assert Poller.cancel_watchdog(%{}) == :ok
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
