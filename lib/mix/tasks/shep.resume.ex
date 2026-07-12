defmodule Mix.Tasks.Shep.Resume do
  @shortdoc "Resume a paused Shep task."
  @moduledoc "Resume a previously paused agent using its preserved worktree and session."

  use Mix.Task

  @impl true
  def run(args) do
    case parse_args(args) do
      {:ok, task_id} ->
        {source, result} = Shep.Control.call(Shep.Orchestrator, :resume, [task_id])
        if source == :local, do: Mix.shell().info("(no daemon found; acting on local node)")

        case result do
          :ok ->
            Mix.shell().info("Task #{task_id} resumed.")

          {:error, reason} ->
            Mix.shell().error("Resume failed: #{reason}")
        end

      :error ->
        Mix.shell().error("Usage: mix shep.resume --task <id>")
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [task: :string]) do
      {[task: id], _, _} -> {:ok, id}
      _ -> :error
    end
  end
end
