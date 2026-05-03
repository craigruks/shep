defmodule Factory.Tracker do
  @moduledoc "Pluggable tracker interface for issue/task management."

  @type task :: Factory.Task.t()
  @type status :: String.t()

  @callback fetch_candidates() :: {:ok, [task()]} | {:error, term()}
  @callback claim(task_id :: String.t()) :: :ok | {:error, term()}
  @callback update_status(task_id :: String.t(), status()) :: :ok | {:error, term()}
  @callback add_comment(task_id :: String.t(), body :: String.t()) :: :ok | {:error, term()}

  @doc "Get the configured tracker module."
  @spec adapter() :: module()
  def adapter do
    config = Factory.Config.current!()

    case get_in(config, ["tracker", "kind"]) do
      "github" -> Factory.Tracker.GitHub
      "memory" -> Factory.Tracker.Memory
      other -> raise "Unknown tracker kind: #{inspect(other)}"
    end
  end

  @doc "Fetch candidate tasks from the configured tracker."
  @spec fetch_candidates() :: {:ok, [task()]} | {:error, term()}
  def fetch_candidates, do: adapter().fetch_candidates()

  @doc "Claim a task."
  @spec claim(String.t()) :: :ok | {:error, term()}
  def claim(task_id), do: adapter().claim(task_id)

  @doc "Update task status."
  @spec update_status(String.t(), status()) :: :ok | {:error, term()}
  def update_status(task_id, status), do: adapter().update_status(task_id, status)

  @doc "Add a comment to a task."
  @spec add_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def add_comment(task_id, body), do: adapter().add_comment(task_id, body)
end
