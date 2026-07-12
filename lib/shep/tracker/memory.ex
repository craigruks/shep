defmodule Shep.Tracker.Memory do
  @moduledoc "In-memory tracker adapter for tests. Stores state in an Agent process."

  @behaviour Shep.Tracker

  use Agent

  @doc "Start the memory tracker with optional initial tasks."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    initial = Keyword.get(opts, :tasks, [])
    state = %{tasks: initial, statuses: %{}, comments: %{}}
    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  @doc "Add a task to the memory tracker."
  @spec add_task(Shep.Task.t()) :: :ok
  def add_task(%Shep.Task{} = task) do
    Agent.update(__MODULE__, fn state ->
      %{state | tasks: [task | state.tasks]}
    end)
  end

  @doc "Get the current status of a task."
  @spec get_status(String.t()) :: String.t() | nil
  def get_status(task_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.statuses, task_id) end)
  end

  @doc "Get comments for a task."
  @spec get_comments(String.t()) :: [String.t()]
  def get_comments(task_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.comments, task_id, []) end)
  end

  @impl true
  def fetch_candidates do
    tasks = Agent.get(__MODULE__, fn state -> state.tasks end)
    {:ok, tasks}
  end

  @impl true
  def claim(task_id) do
    Agent.update(__MODULE__, fn state ->
      %{state | statuses: Map.put(state.statuses, task_id, "in-progress")}
    end)
  end

  @impl true
  def update_status(task_id, status) do
    Agent.update(__MODULE__, fn state ->
      %{state | statuses: Map.put(state.statuses, task_id, status)}
    end)
  end

  @impl true
  def add_comment(task_id, body) do
    Agent.update(__MODULE__, fn state ->
      comments = Map.get(state.comments, task_id, [])
      %{state | comments: Map.put(state.comments, task_id, comments ++ [body])}
    end)
  end
end
