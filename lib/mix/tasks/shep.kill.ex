defmodule Mix.Tasks.Shep.Kill do
  @shortdoc "Kill a running Shep task."
  @moduledoc "Kill a running agent. No retry; the worktree is preserved for post-mortem."

  use Mix.Task

  @impl true
  def run(args) do
    case parse_args(args) do
      {:ok, task_id} ->
        {source, result} = Shep.Control.call(Shep.Orchestrator, :kill, [task_id])
        if source == :local, do: Mix.shell().info("(no daemon found; acting on local node)")

        case result do
          :ok ->
            Mix.shell().info("Killed task #{task_id}. Worktree preserved.")

          {:error, reason} ->
            Mix.shell().error("Kill failed: #{reason}")
        end

      :error ->
        Mix.shell().error("Usage: mix shep.kill --task <id>")
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [task: :string]) do
      {[task: id], _, _} -> {:ok, id}
      _ -> :error
    end
  end
end
