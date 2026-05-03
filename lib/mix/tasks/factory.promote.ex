defmodule Mix.Tasks.Factory.Promote do
  @shortdoc "Promote staging to main and transition in-review issues."
  @moduledoc "Merges staging into main, syncs back, and transitions issue labels."

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    config = Factory.Config.current!()
    repo = get_in(config, ["tracker", "repo"])
    base = get_in(config, ["staging", "base_branch"]) || "staging"

    Mix.shell().info("Promoting #{base} → main...")

    with :ok <- merge_to_main(base),
         :ok <- sync_main_back(base),
         {:ok, count} <- transition_issues(repo) do
      Mix.shell().info("Promoted. #{count} issue(s) transitioned to factory:promoted.")
    else
      {:error, reason} ->
        Mix.shell().error("Promote failed: #{reason}")
    end
  end

  defp merge_to_main(base) do
    case System.cmd("git", ["merge", base, "--ff-only"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, "merge failed: #{String.trim(out)}"}
    end
  end

  defp sync_main_back(base) do
    case System.cmd("git", ["checkout", base], stderr_to_stdout: true) do
      {_, 0} ->
        case System.cmd("git", ["merge", "main", "--ff-only"], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, _} -> {:error, "sync back failed: #{String.trim(out)}"}
        end

      {out, _} ->
        {:error, "checkout failed: #{String.trim(out)}"}
    end
  end

  defp transition_issues(repo) do
    args = [
      "issue",
      "list",
      "--repo",
      repo,
      "--label",
      "factory:in-review",
      "--json",
      "number",
      "--limit",
      "50"
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} ->
        issues = Jason.decode!(output)

        Enum.each(issues, fn %{"number" => num} ->
          id = to_string(num)
          Factory.Tracker.update_status(id, "promoted")
        end)

        {:ok, length(issues)}

      {output, _} ->
        {:error, String.trim(output)}
    end
  end
end
