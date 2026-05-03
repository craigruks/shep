defmodule Mix.Tasks.Factory.Pause do
  @shortdoc "Pause a running factory task."
  @moduledoc "Pause a running agent, preserving its worktree and session for human takeover."

  use Mix.Task

  @impl true
  def run(args) do
    case parse_args(args) do
      {:ok, task_id} ->
        Mix.Task.run("app.start")

        case Factory.Orchestrator.pause(task_id) do
          {:ok, meta} ->
            IO.puts(Jason.encode!(meta, pretty: true))

          {:error, reason} ->
            Mix.shell().error("Pause failed: #{reason}")
        end

      :error ->
        Mix.shell().error("Usage: mix factory.pause --task <id>")
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [task: :string]) do
      {[task: id], _, _} -> {:ok, id}
      _ -> :error
    end
  end
end
