defmodule Mix.Tasks.Shep.Status do
  @shortdoc "Output orchestrator state as JSON."
  @moduledoc "Print running, paused, and claimed tasks as JSON to stdout."

  use Mix.Task

  @impl true
  def run(_args) do
    Application.put_env(:logger, :level, :none)
    {_source, snapshot} = Shep.Control.call(Shep.Orchestrator, :snapshot, [])

    snapshot
    |> project()
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  @doc """
  Project a daemon snapshot into the reportable JSON shape.

  `elapsed_ms`/`idle_ms` are passed through verbatim from the snapshot,
  which computes them daemon-side against a valid monotonic origin. This
  task never subtracts monotonic timestamps itself: a control-VM query
  has no shared origin with the daemon, so any local subtraction would be
  meaningless (and often negative).
  """
  @spec project(map()) :: map()
  def project(snapshot) do
    running =
      Map.new(snapshot[:running] || %{}, fn {id, info} ->
        {id,
         %{
           type: info[:task_type] || "custom",
           elapsed_ms: info[:elapsed_ms],
           idle_ms: info[:idle_ms]
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

    %{
      running: running,
      running_count: map_size(running),
      paused: paused,
      paused_count: map_size(paused),
      claimed: snapshot[:claimed] || []
    }
  end
end
