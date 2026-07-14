defmodule Mix.Tasks.Shep.Promote do
  @shortdoc "Open the staging → main promotion PR (open-the-gate-and-stop)."
  @moduledoc """
  Opens a `staging → main` promotion PR and stops. Reading and merging it is
  the human gate — this task never merges.

  The title is `Release v<version>: <headline>`. The headline and the body's
  "changes being promoted" list are derived from the *content delta* between
  `main` and the staging base, not from raw commit ancestry:

    * A `git fetch` runs first and the comparison uses the remote-tracking
      refs (`<branch>@{upstream}`, falling back to `<remote>/<branch>`, then to
      the local branch), so the result never depends on the operator having
      pre-synced local refs.
    * `git cherry` (patch-id equivalence) drops commits whose change already
      landed on `main` under a different SHA via a squash or promotion merge.
      Raw `git log main..base` lists those forever, since the staging-side
      squash commit is not an ancestor of `main`.

  Squash-merge commit subjects are the merged PR titles (`… (#N)`), so the
  headline is the highest-signal promoted subject rather than a bare
  "N changes" count.

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
  Open the promotion PR for `config`, resolving the change list against `cwd`'s
  repo.

  Exposed for tests: git runs in `cwd` (against a fresh fetch of the remote
  tracking refs) and PRs go through the `Shep.GH` seam, so both are injectable
  without a merge ever being issued.
  """
  @spec promote(map(), String.t()) :: :ok
  def promote(config, cwd) do
    repo = get_in(config, ["tracker", "repo"])
    base = get_in(config, ["staging", "base_branch"]) || "staging"

    fetch(cwd)
    main_ref = tracking_ref("main", cwd)
    base_ref = tracking_ref(base, cwd)

    case promoted_subjects(main_ref, base_ref, cwd) do
      [] ->
        Mix.shell().info("Nothing to promote: #{base} has no changes beyond main.")

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

  # Best-effort sync of the remote-tracking refs before comparing. A repo with
  # no remote (some tests) fails harmlessly; the comparison then falls back to
  # the local branches.
  defp fetch(cwd), do: git(["fetch", "--quiet"], cwd)

  # Resolve the ref to compare `branch` against: its configured upstream, else
  # the default remote's `<remote>/<branch>` if it exists, else the local
  # branch. Never hardcodes a remote name.
  defp tracking_ref(branch, cwd) do
    upstream_ref(branch, cwd) || remote_ref(branch, cwd) || branch
  end

  defp upstream_ref(branch, cwd) do
    case git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "#{branch}@{upstream}"], cwd) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp remote_ref(branch, cwd) do
    with remote when is_binary(remote) <- default_remote(cwd),
         ref = "#{remote}/#{branch}",
         {_, 0} <- git(["rev-parse", "--verify", "--quiet", ref], cwd) do
      ref
    else
      _ -> nil
    end
  end

  # Prefer "origin", else the first configured remote, else none.
  defp default_remote(cwd) do
    case git(["remote"], cwd) do
      {out, 0} ->
        case String.split(out, "\n", trim: true) do
          [] -> nil
          remotes -> if "origin" in remotes, do: "origin", else: hd(remotes)
        end

      _ ->
        nil
    end
  end

  # Subjects of commits on base whose change is not yet on main, newest first.
  # `git cherry -v` marks patch-id-equivalent commits (already applied to main
  # via squash/promotion) with "-" and genuinely new commits with "+". Empty
  # output or a git failure (e.g. main absent) yields [] rather than a crash.
  defp promoted_subjects(main_ref, base_ref, cwd) do
    case git(["cherry", "-v", main_ref, base_ref], cwd) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "+ "))
        |> Enum.map(&cherry_subject/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.reverse()

      _ ->
        []
    end
  end

  # "+ <sha> <subject>" -> "<subject>".
  defp cherry_subject(line) do
    case line |> String.replace_prefix("+ ", "") |> String.split(" ", parts: 2) do
      [_sha, subject] -> String.trim(subject)
      _ -> ""
    end
  end

  defp title(subjects), do: "Release v#{version()}: #{headline(subjects)}"

  # A real headline from the promoted PR subjects, never a bare count.
  defp headline([one]), do: clean(one)
  defp headline([a, b]), do: "#{clean(a)}; #{clean(b)}"
  defp headline(subjects), do: subjects |> highest_signal() |> clean()

  # Prefer a feature/release subject; else the newest (subjects are newest-first).
  defp highest_signal(subjects) do
    Enum.find(subjects, hd(subjects), &(&1 =~ ~r/^(feat|release)/i))
  end

  # Strip the trailing " (#N)" PR suffix and any conventional-commit type prefix
  # for a clean headline, keeping the original if stripping empties it.
  defp clean(subject) do
    subject
    |> String.replace(~r/\s*\(#\d+\)\s*$/, "")
    |> strip_type()
    |> String.trim()
  end

  defp strip_type(subject) do
    stripped = String.replace(subject, ~r/^[a-z]+(\([^)]*\))?!?:\s+/i, "")
    if String.trim(stripped) == "", do: subject, else: stripped
  end

  defp body(subjects) do
    list = Enum.map_join(subjects, "\n", &"- #{&1}")

    """
    Promotes `staging` → `main`.

    ## Changes being promoted

    #{list}

    ---
    Opened by Shep. Review and merge is the human gate.
    """
  end

  defp version do
    to_string(Application.spec(:shep, :vsn) || Mix.Project.config()[:version])
  end

  defp git(args, cwd), do: System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
end
