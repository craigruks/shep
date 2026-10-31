defmodule Mix.Tasks.Shep.Doctor do
  @shortdoc "Check push auth, email, labels, agent CLI and workspace before the first dispatch."
  @moduledoc """
  Pre-flight for the repo in the active workflow (`SHEP_WORKFLOW`, else
  `WORKFLOW.md`). Prints one ✓/✗ line per check, with the exact fix
  command under each ✗. Exits non-zero unless every check passes.

      mix shep.doctor

  Never boots the application, so it cannot start a second orchestrator
  next to a running daemon.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    workflow = Application.get_env(:shep, :workflow_path, "WORKFLOW.md")

    case Shep.Config.load(workflow) do
      {:ok, config} ->
        checks = Shep.Doctor.run(config, workflow: workflow)
        Mix.shell().info("Shep doctor — #{workflow}\n\n" <> Shep.Doctor.format(checks))
        unless Shep.Doctor.ok?(checks), do: exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("✗ workflow: #{reason}\n    fix: $EDITOR #{workflow}")
        exit({:shutdown, 1})
    end
  end
end
