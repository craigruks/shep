defmodule Mix.Tasks.Shep.List do
  @shortdoc "List available templates and current orchestrator state."
  @moduledoc "Show Shep templates, running tasks, and queued candidates."

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    print_templates()
    print_state()
  end

  defp print_templates do
    templates = Shep.PromptBuilder.list_templates()
    Mix.shell().info("\nTemplates:")

    if templates == [] do
      Mix.shell().info("  (none found)")
    else
      Enum.each(templates, &Mix.shell().info("  - #{&1}"))
    end
  end

  defp print_state do
    state = Shep.Orchestrator.snapshot()

    Mix.shell().info("\nRunning tasks:")

    case state[:running] do
      running when running == %{} ->
        Mix.shell().info("  (none)")

      running when is_map(running) ->
        Enum.each(running, fn {id, info} ->
          Mix.shell().info("  #{id}: #{info[:task_type] || "custom"}")
        end)
    end

    Mix.shell().info("")
  end
end
