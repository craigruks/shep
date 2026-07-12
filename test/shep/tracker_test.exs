defmodule Shep.TrackerTest do
  # Touches the :tracker_adapter app env, so no concurrent cases.
  use ExUnit.Case, async: false

  test "adapter resolves from config kind (github by default here)" do
    assert Shep.Tracker.GitHub == Shep.Tracker.adapter()
  end

  test "the :tracker_adapter app env overrides the config-derived adapter" do
    Application.put_env(:shep, :tracker_adapter, Shep.Tracker.Memory)
    on_exit(fn -> Application.delete_env(:shep, :tracker_adapter) end)

    assert Shep.Tracker.Memory == Shep.Tracker.adapter()
  end
end
