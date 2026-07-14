defmodule Shep.ReleaseTest do
  # Boots the shared :shep application and (in one case) cycles the
  # orchestrator child, so it must not run concurrently with siblings
  # that read Orchestrator.snapshot/0.
  use ExUnit.Case, async: false

  alias Shep.Release

  # smoke/0 overrides :workflow_path; restore it so it can't leak into
  # a later test that boots or reloads Shep.Config.
  setup do
    prior = Application.get_env(:shep, :workflow_path)

    on_exit(fn ->
      if prior do
        Application.put_env(:shep, :workflow_path, prior)
      else
        Application.delete_env(:shep, :workflow_path)
      end
    end)

    :ok
  end

  test "smoke/0 boots the app and returns :ok against a live supervision tree" do
    assert Release.smoke() == :ok
  end

  test "the health assertion depends on the orchestrator being up" do
    # Prove the check is not a tautology: with the orchestrator down its
    # ETS-backed snapshot is gone, so the assertion smoke/0 makes raises.
    :ok = Supervisor.terminate_child(Shep.Supervisor, Shep.Orchestrator)

    on_exit(fn ->
      Supervisor.restart_child(Shep.Supervisor, Shep.Orchestrator)
    end)

    assert_raise ArgumentError, fn -> Shep.Orchestrator.snapshot() end

    # Restore the orchestrator and confirm the same assertion now holds,
    # so smoke/0 succeeds exactly when the tree is alive.
    {:ok, _pid} = Supervisor.restart_child(Shep.Supervisor, Shep.Orchestrator)
    assert %{running: running} = Shep.Orchestrator.snapshot()
    assert is_map(running)
  end

  test "version/0 reports the mix project version" do
    assert Release.version() =~ ~r/^\d+\.\d+\.\d+/
  end
end
