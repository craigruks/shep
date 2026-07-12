defmodule Mix.Tasks.Shep.Agent do
  @shortdoc "Run a Shep agent on a specific issue."
  @moduledoc "Execute a Shep agent for the given issue number."

  use Mix.Task

  @poll_interval_ms 2_000

  @impl true
  def run(args) do
    case parse_args(args) do
      {:ok, issue_number} ->
        Mix.Task.run("app.start")
        execute(issue_number)

      :error ->
        Mix.shell().error("Usage: mix shep.agent --issue <number>")
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [issue: :string]) do
      {[issue: num], _, _} -> {:ok, num}
      _ -> :error
    end
  end

  defp execute(issue_number) do
    config = Shep.Config.current!()
    repo = get_in(config, ["tracker", "repo"])
    base_branch = get_in(config, ["staging", "base_branch"]) || "staging"

    Mix.shell().info("Fetching issue ##{issue_number} from #{repo}...")

    case fetch_issue(repo, issue_number) do
      {:ok, issue} ->
        task = build_task(issue, base_branch)
        merge_note = if task.no_merge, do: ", no-merge", else: ""

        Mix.shell().info(
          "Submitting task #{task.id} (type: #{task.type || "custom"}#{merge_note})..."
        )

        case Shep.Orchestrator.submit(task) do
          :ok ->
            Mix.shell().info("Task submitted. Waiting for completion...")
            wait_for_completion(task.id)

          {:error, reason} ->
            Mix.shell().error("Submit failed: #{reason}")
        end

      {:error, reason} ->
        Mix.shell().error("Could not fetch issue: #{reason}")
    end
  end

  defp wait_for_completion(task_id) do
    Process.sleep(@poll_interval_ms)
    snapshot = Shep.Orchestrator.snapshot()
    running = snapshot.running

    cond do
      Map.has_key?(running, task_id) ->
        wait_for_completion(task_id)

      map_size(running) > 0 ->
        other_ids = running |> Map.keys() |> Enum.join(", ")
        Mix.shell().info("Task #{task_id} finished. Waiting for sibling tasks: #{other_ids}")
        wait_for_all(running)

      true ->
        Mix.shell().info("Task #{task_id} finished.")
    end
  end

  defp wait_for_all(prev_running) do
    Process.sleep(@poll_interval_ms)
    snapshot = Shep.Orchestrator.snapshot()

    if map_size(snapshot.running) > 0 do
      wait_for_all(snapshot.running)
    else
      ids = prev_running |> Map.keys() |> Enum.join(", ")
      Mix.shell().info("All tasks finished (#{ids}).")
    end
  end

  defp fetch_issue(repo, number) do
    args = ["issue", "view", number, "--repo", repo, "--json", "number,title,body,labels"]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, Jason.decode!(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp build_task(issue, base_branch) do
    number = to_string(issue["number"])
    labels = issue["labels"] || []
    task_type = Shep.Tracker.GitHub.parse_task_type(labels)

    %Shep.Task{
      id: number,
      branch: "shep/#{number}",
      base_branch: base_branch,
      prompt: issue["body"] || issue["title"],
      prompt_args: %{
        "ISSUE_NUMBER" => number,
        "ISSUE_TITLE" => issue["title"] || "",
        "SOURCE_BRANCH" => "shep/#{number}",
        "TARGET_BRANCH" => base_branch
      },
      type: task_type,
      depends_on: Shep.Tracker.GitHub.parse_depends_on(issue["body"]),
      agent: Shep.Tracker.GitHub.parse_agent(labels),
      no_merge: Shep.Tracker.GitHub.no_merge?(labels)
    }
  end
end
