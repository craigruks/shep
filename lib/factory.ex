defmodule Factory do
  @moduledoc "Dark Factory — autonomous agent orchestration for the LayerKick platform."

  @doc "Submit a task for agent execution."
  @spec run(map()) :: :ok | {:error, String.t()}
  def run(attrs) when is_map(attrs) do
    task = %Factory.Task{
      id: Map.get(attrs, :id, generate_id()),
      branch: Map.fetch!(attrs, :branch),
      base_branch: Map.get(attrs, :base_branch, "staging"),
      prompt: Map.fetch!(attrs, :prompt),
      prompt_args: Map.get(attrs, :prompt_args, %{}),
      type: Map.get(attrs, :type),
      depends_on: Map.get(attrs, :depends_on)
    }

    Factory.Orchestrator.submit(task)
  end

  @doc "Get current orchestrator state snapshot."
  @spec status() :: map()
  def status, do: Factory.Orchestrator.snapshot()

  @doc "Get current config."
  @spec config() :: {:ok, map()} | {:error, String.t()}
  def config, do: Factory.Config.current()

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
