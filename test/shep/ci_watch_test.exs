defmodule Shep.CIWatchTest do
  # Touches the :ci_watch_adapter app env, so no concurrent cases.
  use ExUnit.Case, async: false

  test "adapter defaults to the GitHub implementation" do
    assert Shep.CIWatch.GitHub == Shep.CIWatch.adapter()
  end

  test "the :ci_watch_adapter app env overrides the default" do
    Application.put_env(:shep, :ci_watch_adapter, Shep.CIWatchStub)
    on_exit(fn -> Application.delete_env(:shep, :ci_watch_adapter) end)

    assert Shep.CIWatchStub == Shep.CIWatch.adapter()
  end
end
