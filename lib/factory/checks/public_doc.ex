defmodule Factory.Checks.PublicDoc do
  @moduledoc false

  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      Every public function should have a @doc attribute.
      This ensures `h Module.function` works in IEx.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta))
  end

  defp traverse({:def, meta, [{name, _, _args} | _]} = ast, issues, issue_meta) do
    case meta[:doc] do
      nil ->
        {ast, issues}

      false ->
        issue =
          format_issue(issue_meta,
            message: "Public function `#{name}` is missing @doc.",
            trigger: "#{name}",
            line_no: meta[:line]
          )

        {ast, [issue | issues]}

      _ ->
        {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end
end
