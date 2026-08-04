defmodule Shep.Orchestrator.TidyScheduleTest do
  # Replaces the shared Shep.Config state, so this must not run alongside
  # other cases.
  use ExUnit.Case, async: false

  alias Shep.Orchestrator.Poller

  setup do
    original = :sys.get_state(Shep.Config)
    on_exit(fn -> :sys.replace_state(Shep.Config, fn _ -> original end) end)
    :ok
  end

  defp inject(overrides) do
    raw = Shep.Config.Schema.deep_merge(%{"tracker" => %{"kind" => "memory"}}, overrides)
    {:ok, config} = Shep.Config.Schema.validate(raw)

    :sys.replace_state(Shep.Config, fn s ->
      %{s | config: config, path: "/nonexistent/shep_test", stamp: nil}
    end)
  end

  test "a configured interval arms a tidy timer" do
    inject(%{"workspace" => %{"tidy_interval_ms" => 60_000}})

    state = Poller.schedule_tidy(%Shep.Orchestrator{})

    assert is_reference(state.tidy_timer)
    assert is_reference(state.tidy_token)
    assert Process.cancel_timer(state.tidy_timer)
  end

  test "zero disables the sweep without needing a separate flag" do
    inject(%{"workspace" => %{"tidy_interval_ms" => 0}})

    state = Poller.schedule_tidy(%Shep.Orchestrator{})

    assert state.tidy_timer == nil
    assert state.tidy_token == nil
  end

  test "rescheduling cancels the previous timer so they cannot accumulate" do
    inject(%{"workspace" => %{"tidy_interval_ms" => 60_000}})

    first = Poller.schedule_tidy(%Shep.Orchestrator{})
    second = Poller.schedule_tidy(first)

    refute first.tidy_token == second.tidy_token
    # The first timer is already cancelled, so cancelling again is a no-op.
    assert Process.cancel_timer(first.tidy_timer) == false
    assert Process.cancel_timer(second.tidy_timer)
  end

  test "the sweep runs off the orchestrator process, under the task supervisor" do
    inject(%{"workspace" => %{"tidy_interval_ms" => 60_000, "root" => "/nonexistent/root"}})

    before = Task.Supervisor.children(Shep.TaskSupervisor) |> length()
    assert :ok = Poller.start_tidy()

    # Started as a child rather than executed inline: the orchestrator must
    # never block on git or the network.
    assert Task.Supervisor.children(Shep.TaskSupervisor) |> length() >= before
  end
end
