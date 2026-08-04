defmodule Mix.Tasks.Shep.Tidy do
  @shortdoc "Reclaim worktrees and sandboxes no live task owns."
  @moduledoc """
  Report every workspace under the configured root and reclaim the ones
  holding nothing that is not already on a remote.

      mix shep.tidy              # report, then reclaim what is safe
      mix shep.tidy --dry-run    # report only, touch nothing

  Runs on the daemon when one is reachable, so a running or paused task's
  worktree is never mistaken for junk.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [dry_run: :boolean])
    dry_run? = Keyword.get(opts, :dry_run, false)

    {source, report} = Shep.Control.call(Shep.Tidy, :run, [[dry_run: dry_run?]])

    Mix.shell().info("Tidy (#{source}) — #{report.root}#{if dry_run?, do: "  [dry run]", else: ""}")

    case report.entries do
      [] -> Mix.shell().info("  (no worktrees)")
      entries -> Enum.each(entries, &print_entry/1)
    end

    summarize(report, dry_run?)
  end

  defp print_entry(%{decision: decision, path: path, branch: branch, detail: detail}) do
    Mix.shell().info(
      "  #{mark(decision)} #{Path.basename(path)}#{branch_suffix(branch)} — #{detail}"
    )
  end

  defp branch_suffix(nil), do: ""
  defp branch_suffix(branch), do: " [#{branch}]"

  defp mark(:reap), do: "reap "
  defp mark(:busy), do: "busy "
  defp mark(:dirty), do: "keep "
  defp mark(:unpushed), do: "keep "
  defp mark(:foreign), do: "other"
  defp mark(:unreadable), do: "skip "

  defp summarize(report, true) do
    reapable = Enum.count(report.entries, &(&1.decision == :reap))
    Mix.shell().info("\n#{reapable} worktree(s) would be reclaimed. Re-run without --dry-run.")
  end

  defp summarize(report, false) do
    kept = Enum.count(report.entries, &(&1.decision in [:dirty, :unpushed]))

    Mix.shell().info(
      "\nReclaimed #{length(report.reaped)} worktree(s)" <>
        sandbox_note(report.sandboxes) <>
        ", kept #{kept} holding unpushed work."
    )
  end

  defp sandbox_note([]), do: ""
  defp sandbox_note(names), do: " and #{length(names)} sandbox(es)"
end
