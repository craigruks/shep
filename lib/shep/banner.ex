defmodule Shep.Banner do
  @moduledoc """
  The session marker every daemon boot writes into `.shep/orchestrator.log`.

  The log is appended across restarts, not truncated, so the evidence of
  a failed run survives the fix-and-restart cycle that follows it. That
  makes the file a record of many sessions, and a reader needs to tell
  them apart: every boot opens with a `=== shep …` line carrying the
  version, OS pid, node and workflow file in use.

      grep '=== shep' .shep/orchestrator.log

  lists the boundaries; the line also says which config that session ran
  with, which is usually the first question when two boots behaved
  differently.
  """

  require Logger

  @marker "=== shep"

  @doc """
  The banner line for the current session.

  Carries the release version, OS pid, node name, the workflow file the
  session is configured against, and a UTC timestamp (the console format
  logs a time of day only, which is ambiguous in a file spanning days).
  """
  @spec line() :: String.t()
  def line do
    Enum.join(
      [
        "#{@marker} #{Shep.Release.version()} up",
        "pid #{System.pid()}",
        "node #{Node.self()}",
        "workflow #{workflow_path()}",
        "#{timestamp()} ==="
      ],
      " | "
    )
  end

  @doc "The grep handle that starts every banner line."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "Emit `line/0` to the orchestrator log at `:info`."
  @spec log() :: :ok
  def log do
    Logger.info(line())
  end

  defp workflow_path do
    Application.get_env(:shep, :workflow_path) || "(unset)"
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
