defmodule Mix.Tasks.Factory.Triage do
  @shortdoc "Generate a triage checklist from recent factory completions."
  @moduledoc "Reads in-review issues and aggregates verify items into a test checklist."

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    config = Factory.Config.current!()
    repo = get_in(config, ["tracker", "repo"])

    Mix.shell().info("Fetching in-review issues from #{repo}...")

    case fetch_in_review(repo) do
      {:ok, issues} when issues != [] ->
        print_checklist(issues, repo)

      {:ok, []} ->
        Mix.shell().info("No issues in-review. Nothing to triage.")

      {:error, reason} ->
        Mix.shell().error("Failed to fetch issues: #{reason}")
    end
  end

  defp fetch_in_review(repo) do
    args = [
      "issue",
      "list",
      "--repo",
      repo,
      "--label",
      "factory:in-review",
      "--json",
      "number,title,body",
      "--limit",
      "50"
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, Jason.decode!(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp print_checklist(issues, _repo) do
    Mix.shell().info("\n## Factory Triage Checklist\n")
    Mix.shell().info("#{length(issues)} issue(s) in-review since last promotion.\n")

    verify_items =
      issues
      |> Enum.flat_map(&extract_verify_items/1)
      |> Enum.uniq()

    if verify_items == [] do
      Mix.shell().info("No verify items found in completion signals.")
      Mix.shell().info("Review each PR manually before promoting.\n")
    else
      Mix.shell().info("### Verify before promoting to main:\n")
      Enum.each(verify_items, &Mix.shell().info("- [ ] #{&1}"))
      Mix.shell().info("")
    end

    Mix.shell().info("### Issues:\n")

    Enum.each(issues, fn issue ->
      Mix.shell().info("- ##{issue["number"]}: #{issue["title"]}")
    end)

    Mix.shell().info("\nRun `just factory-promote` when ready.")
  end

  defp extract_verify_items(issue) do
    body = issue["body"] || ""

    case Regex.run(~r/<completion>(.*?)<\/completion>/s, body) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, %{"verify" => items}} when is_list(items) -> items
          _ -> []
        end

      _ ->
        []
    end
  end
end
