defmodule Shep.GHTest do
  # Touches the :gh_runner app env, so no concurrent cases.
  use ExUnit.Case, async: false

  test "an injected runner receives the argument list verbatim" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn args ->
      send(test_pid, {:gh, args})
      {:ok, "stubbed"}
    end)

    on_exit(fn -> Application.delete_env(:shep, :gh_runner) end)

    assert {:ok, "stubbed"} = Shep.GH.run(["pr", "view", "1"])
    assert_received {:gh, ["pr", "view", "1"]}
  end

  test "the default runner shells out to gh and trims stdout" do
    Application.delete_env(:shep, :gh_runner)
    assert {:ok, out} = Shep.GH.run(["--version"])
    assert out =~ "gh version"
  end
end
