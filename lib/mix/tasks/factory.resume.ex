defmodule Mix.Tasks.Factory.Resume do
  @shortdoc "Resume a paused factory task."
  @moduledoc "Resume a previously paused agent using its preserved worktree and session."

  use Mix.Task

  @impl true
  def run(args) do
    case parse_args(args) do
      {:ok, task_id} ->
        Mix.Task.run("app.start")

        case Factory.Orchestrator.resume(task_id) do
          :ok ->
            Mix.shell().info("Task #{task_id} resumed.")

          {:error, reason} ->
            Mix.shell().error("Resume failed: #{reason}")
        end

      :error ->
        Mix.shell().error("Usage: mix factory.resume --task <id>")
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [task: :string]) do
      {[task: id], _, _} -> {:ok, id}
      _ -> :error
    end
  end
end
