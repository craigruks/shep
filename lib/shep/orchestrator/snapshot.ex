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

  @doc "Read the latest snapshot, or an empty projection if none written yet."
  @spec read() :: map()
  def read do
    case :ets.lookup(@table, :state) do
      [{:state, data}] -> data
      [] -> %{running: %{}}
    end
  end

  @doc "Project and store the orchestrator state for zero-contention reads."
  @spec write(struct()) :: :ok
  def write(state) do
    data = %{
      running:
        Map.new(state.running, fn {id, entry} ->
          {id,
           %{
             task_type: entry.task.type,
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
