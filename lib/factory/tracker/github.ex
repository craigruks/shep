defmodule Factory.Tracker.GitHub do
  @moduledoc "GitHub Issues tracker adapter. Uses `gh` CLI for all operations."

  @behaviour Factory.Tracker

  require Logger

  @label_queued "factory"
  @label_in_progress "factory:in-progress"
  @label_pr_created "factory:pr-created"
  @label_in_review "factory:in-review"
  @label_failed "factory:failed"

  @label_promoted "factory:promoted"
  @label_no_merge "factory:no-merge"
  @label_codex "factory:codex"

  @status_labels %{
    "in-progress" => @label_in_progress,
    "pr-created" => @label_pr_created,
    "in-review" => @label_in_review,
    "failed" => @label_failed,
    "promoted" => @label_promoted
  }

  @impl true
  def fetch_candidates do
    config = Factory.Config.current!()
    repo = get_in(config, ["tracker", "repo"])
    base_branch = get_in(config, ["staging", "base_branch"]) || "staging"

    case gh([
           "issue",
           "list",
           "--repo",
           repo,
           "--label",
           @label_queued,
           "--json",
           "number,title,body,labels",
           "--limit",
           "20"
         ]) do
      {:ok, json} ->
        issues = Jason.decode!(json)
        tasks = Enum.map(issues, &issue_to_task(&1, base_branch))
        {:ok, tasks}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def claim(task_id) do
    config = Factory.Config.current!()
    repo = get_in(config, ["tracker", "repo"])

    with :ok <- remove_label(repo, task_id, @label_queued),
         :ok <- add_label(repo, task_id, @label_in_progress) do
      :ok
    end
  end

  @impl true
  def update_status(task_id, status) do
    config = Factory.Config.current!()
    repo = get_in(config, ["tracker", "repo"])

    case Map.get(@status_labels, status) do
      nil ->
        {:error, "unknown status: #{status}"}

      label ->
        clear_factory_labels(repo, task_id)
        add_label(repo, task_id, label)
    end
  end

  @impl true
  def add_comment(task_id, body) do
    config = Factory.Config.current!()
    repo = get_in(config, ["tracker", "repo"])

    case gh(["issue", "comment", task_id, "--repo", repo, "--body", body]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Parse task type from issue labels (e.g. `type:lint-fix`)."
  @spec parse_task_type([map()]) :: String.t() | nil
  def parse_task_type(labels) when is_list(labels) do
    Enum.find_value(labels, fn
      %{"name" => "type:" <> type} -> type
      _ -> nil
    end)
  end

  @doc "Parse dependency refs from issue body (`Depends on: #12, #45`)."
  @spec parse_depends_on(String.t() | nil) :: [String.t()]
  def parse_depends_on(nil), do: []

  def parse_depends_on(body) when is_binary(body) do
    case Regex.run(~r/Depends on:\s*(.+)/i, body) do
      [_, refs] ->
        Regex.scan(~r/#(\d+)/, refs)
        |> Enum.map(fn [_, num] -> num end)

      _ ->
        []
    end
  end

  @doc "Check if all dependencies are resolved (in-review or promoted)."
  @spec deps_resolved?(String.t(), [String.t()]) :: boolean()
  def deps_resolved?(_repo, []), do: true

  def deps_resolved?(repo, dep_ids) when is_list(dep_ids) do
    Enum.all?(dep_ids, fn id ->
      case gh(["issue", "view", id, "--repo", repo, "--json", "labels"]) do
        {:ok, json} ->
          labels = Jason.decode!(json) |> Map.get("labels", []) |> Enum.map(& &1["name"])
          @label_in_review in labels || "factory:promoted" in labels

        {:error, _} ->
          false
      end
    end)
  end

  @doc "Check if issue labels include factory:no-merge."
  @spec no_merge?([map()]) :: boolean()
  def no_merge?(labels) when is_list(labels) do
    Enum.any?(labels, fn
      %{"name" => @label_no_merge} -> true
      _ -> false
    end)
  end

  @doc "Parse agent type from issue labels. Returns :codex if factory:codex label present, :claude otherwise."
  @spec parse_agent([map()]) :: Factory.Task.agent()
  def parse_agent(labels) when is_list(labels) do
    if Enum.any?(labels, fn
         %{"name" => @label_codex} -> true
         _ -> false
       end),
       do: :codex,
       else: :claude
  end

  defp issue_to_task(issue, base_branch) do
    number = to_string(issue["number"])
    labels = issue["labels"] || []
    task_type = parse_task_type(labels)
    depends_on = parse_depends_on(issue["body"])

    %Factory.Task{
      id: number,
      branch: "factory/#{number}",
      base_branch: base_branch,
      prompt: issue["body"] || issue["title"],
      prompt_args: %{
        "ISSUE_NUMBER" => number,
        "ISSUE_TITLE" => issue["title"] || "",
        "SOURCE_BRANCH" => "factory/#{number}",
        "TARGET_BRANCH" => base_branch
      },
      type: task_type,
      depends_on: depends_on,
      agent: parse_agent(labels),
      no_merge: no_merge?(labels)
    }
  end

  defp add_label(repo, issue_id, label) do
    case gh(["issue", "edit", issue_id, "--repo", repo, "--add-label", label]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_label(repo, issue_id, label) do
    case gh(["issue", "edit", issue_id, "--repo", repo, "--remove-label", label]) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp clear_factory_labels(repo, issue_id) do
    for {_status, label} <- @status_labels do
      remove_label(repo, issue_id, label)
    end

    remove_label(repo, issue_id, @label_queued)
  end

  defp gh(args) when is_list(args) do
    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end
end
