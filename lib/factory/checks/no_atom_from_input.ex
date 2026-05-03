defmodule Factory.Checks.NoAtomFromInput do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Atom table is never garbage collected. Creating atoms from external
      input (String.to_atom, String.to_existing_atom in unsafe contexts,
      Jason.decode with keys: :atoms) can exhaust it.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse(
         {{:., _meta, [{:__aliases__, _, [:String]}, :to_atom]}, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "String.to_atom/1") | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(issue_meta,
      message: "Avoid #{trigger} — atoms are never GC'd. Use strings for external input.",
      trigger: trigger,
      line_no: line_no
    )
  end
end
