defmodule Shep.Orchestrator.Snapshot do
  @moduledoc """
  The read model: a projection of orchestrator state into an ETS table.

  Status reads (`Shep.Orchestrator.snapshot/0`, control commands) hit ETS
  directly, never the GenServer, so a busy orchestrator never blocks a
  status query. The orchestrator writes a fresh projection after every
  state transition.
  """

  @table :shep_state

  @doc "Create the backing ETS table. Called once at orchestrator init."
  @spec new() :: :ok
  def new do
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  @doc """
  Read the latest snapshot, or an empty projection if none written yet.

  Enriches each running task with `elapsed_ms`/`idle_ms` (and `elapsed`,
  the human-readable form of `elapsed_ms`), computed here
  against the daemon's `System.monotonic_time` so the deltas are valid.
  The stored `started_at`/`last_output_at` are per-VM monotonic stamps;
  computing the deltas on the read side (which runs on the daemon node via
  `Shep.Control` RPC) keeps a control-VM caller from subtracting across
  unrelated monotonic origins. Raw stamps stay in the projection for
  same-VM callers; the watchdog reads its own state, not this table.
  """
  @spec read() :: map()
  def read do
    case :ets.lookup(@table, :state) do
      [{:state, data}] -> enrich(data)
      [] -> %{running: %{}}
    end
  end

  defp enrich(%{running: running} = data) do
    now = System.monotonic_time(:millisecond)

    enriched =
      Map.new(running, fn {id, entry} ->
        elapsed_ms = delta(now, entry[:started_at])

        {id,
         Map.merge(entry, %{
           elapsed_ms: elapsed_ms,
           elapsed: format_elapsed(elapsed_ms),
           idle_ms: delta(now, entry[:last_output_at])
         })}
      end)

    %{data | running: enriched}
  end

  defp enrich(data), do: data

  defp delta(_now, nil), do: nil
  defp delta(now, stamp) when is_integer(stamp), do: now - stamp

  @doc """
  Render a millisecond duration for humans: `45s`, `12m 04s`, `1h 02m 03s`.
  `nil` (no stamp to measure from) stays `nil`.
  """
  @spec format_elapsed(integer() | nil) :: String.t() | nil
  def format_elapsed(nil), do: nil

  def format_elapsed(ms) when is_integer(ms) do
    s = div(max(ms, 0), 1000)

    case {div(s, 3600), rem(div(s, 60), 60), rem(s, 60)} do
      {0, 0, sec} -> "#{sec}s"
      {0, min, sec} -> "#{min}m #{pad(sec)}s"
      {h, min, sec} -> "#{h}h #{pad(min)}m #{pad(sec)}s"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "Project and store the orchestrator state for zero-contention reads."
  @spec write(struct()) :: :ok
  def write(state) do
    data = %{
      running:
        Map.new(state.running, fn {id, entry} ->
          {id,
           %{
             task_type: entry.task.type,
             branch: entry.task.branch,
             agent: entry.task.agent,
             location: entry.task.location,
             model: Map.get(entry, :model),
             step: Map.get(entry, :step),
             started_at: entry.started_at,
             last_output_at: entry.last_output_at,
             worktree_path: Map.get(entry, :worktree_path),
             session_name: Map.get(entry, :session_name)
           }}
        end),
      paused:
        Map.new(state.paused, fn {id, pt} ->
          {id,
           %{
             task_type: pt.task.type,
             branch: pt.task.branch,
             worktree_path: pt.worktree_path,
             session_name: pt.session_name,
             paused_at: pt.paused_at
           }}
        end),
      claimed: MapSet.to_list(state.claimed)
    }

    :ets.insert(@table, {:state, data})
    :ok
  end
end
