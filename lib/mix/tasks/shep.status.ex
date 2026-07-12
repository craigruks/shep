defmodule Mix.Tasks.Shep.Status do
  @shortdoc "Output orchestrator state as JSON."
  @moduledoc "Print running tasks, claimed tasks, and totals as JSON to stdout."

  use Mix.Task

  @impl true
  def run(_args) do
    Application.put_env(:logger, :level, :none)
    Mix.Task.run("app.start")

    snapshot = Shep.Orchestrator.snapshot()

    running =
      Map.new(snapshot[:running] || %{}, fn {id, info} ->
        elapsed =
          if info[:started_at],
            do: System.monotonic_time(:millisecond) - info[:started_at],
            else: nil

        idle =
          if info[:last_output_at],
            do: System.monotonic_time(:millisecond) - info[:last_output_at],
            else: nil

        {id,
         %{
           type: info[:task_type] || "custom",
           elapsed_ms: elapsed,
           idle_ms: idle
         }}
      end)

    paused =
      Map.new(snapshot[:paused] || %{}, fn {id, info} ->
        {id,
         %{
           type: info[:task_type] || "custom",
           worktree_path: info[:worktree_path],
           session_name: info[:session_name]
         }}
      end)

    output = %{
      running: running,
      running_count: map_size(running),
      paused: paused,
      paused_count: map_size(paused),
      claimed: snapshot[:claimed] || [],
      totals: snapshot[:totals] || %{}
    }

    IO.puts(Jason.encode!(output, pretty: true))
  end
end
