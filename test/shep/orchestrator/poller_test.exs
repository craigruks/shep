defmodule Shep.Orchestrator.PollerTest do
  # async: false — the tick tests install an app-env tracker adapter.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Shep.Orchestrator.Poller

  # A tracker stand-in that pings the test process on fetch, so we can assert
  # the placeholder guard skips the fetch entirely (no network boundary crossed).
  defmodule TrackerSpy do
    @moduledoc false
    def fetch_candidates do
      if pid = Application.get_env(:shep, :test_tracker_spy), do: send(pid, :fetch_called)
      {:ok, []}
    end

    def claim(_id), do: :ok
    def update_status(_id, _status), do: :ok
    def add_comment(_id, _body), do: :ok
  end

  defp task(id), do: %Shep.Task{id: id, branch: "shep/#{id}", prompt: "p"}

  defp config(repo), do: %{"tracker" => %{"repo" => repo}}

  # The suite runs at :warning; the tick pulse is :info. Capturing it means
  # lowering the primary level for the duration. Safe here — this module is
  # async: false, so nothing else logs concurrently.
  defp capture_info(fun) do
    prev = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: prev)
    end
  end

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

  describe "tick/2 visible pulse + placeholder guard" do
    setup do
      Application.put_env(:shep, :tracker_adapter, TrackerSpy)
      Application.put_env(:shep, :test_tracker_spy, self())

      on_exit(fn ->
        Application.delete_env(:shep, :tracker_adapter)
        Application.delete_env(:shep, :test_tracker_spy)
      end)

      :ok
    end

    test "emits one info pulse per tick naming the repo and idle counts" do
      log =
        capture_info(fn ->
          Poller.tick(%Shep.Orchestrator{}, config("craigruks/shep"))
        end)

      assert log =~ "tick: watching craigruks/shep"
      assert log =~ "idle (0 running, 0 claimed)"
    end

    test "a running task is reflected in the tick line (count > 0)" do
      state = %Shep.Orchestrator{running: %{"30" => %{}}}

      log =
        capture_info(fn ->
          Poller.tick(state, config("craigruks/shep"))
        end)

      assert log =~ "1 running"
      assert log =~ "task 30 running"
    end

    test "a real repo fetches from the tracker normally" do
      Poller.tick(%Shep.Orchestrator{}, config("craigruks/shep"))
      assert_receive :fetch_called, 500
    end

    test "the template placeholder repo warns loudly and skips the fetch" do
      log =
        capture_log(fn ->
          Poller.tick(%Shep.Orchestrator{}, config("your-org/your-repo"))
        end)

      assert log =~ ~s(tracker.repo is "your-org/your-repo")
      assert log =~ "Not polling"
      refute_receive :fetch_called, 100
    end

    test "a nil/blank repo also skips the fetch" do
      Poller.tick(%Shep.Orchestrator{}, config(nil))
      Poller.tick(%Shep.Orchestrator{}, config("   "))
      refute_receive :fetch_called, 100
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
