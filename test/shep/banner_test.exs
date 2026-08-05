defmodule Shep.BannerTest do
  # Reads and (in one case) overrides :workflow_path, which Shep.Config
  # also reads, so it must not run alongside config-mutating siblings.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Shep.Banner

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

  test "line/0 carries version, pid, node, workflow and a UTC timestamp" do
    Application.put_env(:shep, :workflow_path, "/tmp/flock.md")
    line = Banner.line()

    assert String.starts_with?(line, Banner.marker())
    assert line =~ Shep.Release.version()
    assert line =~ "pid #{System.pid()}"
    assert line =~ "node #{Node.self()}"
    assert line =~ "workflow /tmp/flock.md"
    assert line =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
  end

  test "line/0 says so rather than crashing when no workflow is configured" do
    Application.delete_env(:shep, :workflow_path)

    assert Banner.line() =~ "workflow (unset)"
  end

  test "marker/0 is a grep handle that finds every session boundary" do
    log = """
    #{Banner.line()}
    12:00:01 [info] polling
    #{Banner.line()}
    12:00:02 [info] polling
    """

    boundaries =
      log
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, Banner.marker()))

    assert length(boundaries) == 2
  end

  test "log/0 emits the line at :info, where the daemon's log level keeps it" do
    # The suite runs at :warning; the daemon (prod) runs at :info, so drop
    # the primary level for this assertion to see what an operator sees.
    prior = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prior) end)

    logged = capture_log([level: :info], fn -> assert Banner.log() == :ok end)

    assert logged =~ Banner.marker()
    assert logged =~ "[info]"
  end
end
