defmodule Mix.Tasks.Shep.Pause do
  @shortdoc "Pause a running Shep task."
  @moduledoc "Pause a running agent, preserving its worktree and session for human takeover."

  use Mix.Task

  @impl true
  def run(args) do
    case parse_args(args) do
      {:ok, task_id} ->
        {source, result} = Shep.Control.call(Shep.Orchestrator, :pause, [task_id])
        if source == :local, do: Mix.shell().info("(no daemon found; acting on local node)")

        case result do
          {:ok, meta} ->
            IO.puts(Jason.encode!(meta, pretty: true))

          {:error, reason} ->
            Mix.shell().error("Pause failed: #{reason}")
        end

      :error ->
        Mix.shell().error("Usage: mix shep.pause --task <id>")
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [task: :string]) do
      {[task: id], _, _} -> {:ok, id}
      _ -> :error
    end
  end
end
