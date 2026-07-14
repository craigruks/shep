defmodule Mix.Tasks.Shep.Promote do
  @shortdoc "Open the staging → main promotion PR (open-the-gate-and-stop)."
  @moduledoc """
  Opens a `staging → main` promotion PR and stops. Reading and merging it is
  the human gate — this task never merges.

  The title is auto-generated as `Release v<version>: <headline>`, where the
  headline summarizes the commits on the staging branch that are not yet on
  `main`. The full list of promoted commit subjects goes in the PR body.

  Follow-up (out of scope here): the `shep:in-review → shep:promoted` label
  transition must move to a push-to-main trigger, since this task now runs
  before the merge rather than after it.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    promote(Shep.Config.current!(), File.cwd!())
  end

  @doc """
  Open the promotion PR for `config`, resolving commits against `cwd`'s repo.

  Exposed for tests: git (`main..<base>`) runs in `cwd` and PRs go through the
  `Shep.GH` seam, so both are injectable without a merge ever being issued.
  """
  @spec promote(map(), String.t()) :: :ok
  def promote(config, cwd) do
    repo = get_in(config, ["tracker", "repo"])
    base = get_in(config, ["staging", "base_branch"]) || "staging"

    case promoted_subjects(base, cwd) do
      [] ->
        Mix.shell().info("Nothing to promote: #{base} is not ahead of main.")

      subjects ->
        open_or_report(repo, base, subjects)
    end
  end

  # Open the promotion PR, unless one from base → main is already open.
  defp open_or_report(repo, base, subjects) do
    case existing_pr(repo, base) do
      {:ok, url} ->
        Mix.shell().info("Promotion PR already open: #{url}")

      :none ->
        create_pr(repo, base, subjects)
    end
  end

  defp create_pr(repo, base, subjects) do
    args = [
      "pr",
      "create",
      "--repo",
      repo,
      "--base",
      "main",
      "--head",
      base,
      "--title",
      title(subjects),
      "--body",
      body(subjects)
    ]

    case Shep.GH.run(args) do
      {:ok, url} -> Mix.shell().info("Promotion PR opened: #{url}")
      {:error, reason} -> Mix.shell().error("Promote failed: #{reason}")
    end
  end

  # Subjects of commits on base but not on main, newest first. An empty list
  # means base is not ahead of main (nothing to promote). A git failure (e.g.
  # main absent locally) also yields [] rather than a crash.
  defp promoted_subjects(base, cwd) do
    case System.cmd("git", ["log", "main..#{base}", "--format=%s"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      {_, _} -> []
    end
  end

  # Report an already-open base → main PR so we never error on a duplicate.
  defp existing_pr(repo, base) do
    args = [
      "pr",
      "list",
      "--repo",
      repo,
      "--base",
      "main",
      "--head",
      base,
      "--state",
      "open",
      "--json",
      "url"
    ]

    with {:ok, out} <- Shep.GH.run(args),
         {:ok, [%{"url" => url} | _]} <- Jason.decode(out) do
      {:ok, url}
    else
      _ -> :none
    end
  end

  defp title(subjects), do: "Release v#{version()}: #{headline(subjects)}"

  # One-line headline: the single subject, two joined, or an N-changes summary.
  defp headline([one]), do: one
  defp headline([a, b]), do: "#{a}; #{b}"
  defp headline(subjects), do: "#{length(subjects)} changes"

  defp body(subjects) do
    list = Enum.map_join(subjects, "\n", &"- #{&1}")

    """
    Promotes `staging` → `main`.

    ## Commits being promoted

    #{list}

    ---
    Opened by Shep. Review and merge is the human gate.
    """
  end

  defp version do
    to_string(Application.spec(:shep, :vsn) || Mix.Project.config()[:version])
  end
end
