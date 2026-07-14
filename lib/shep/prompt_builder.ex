defmodule Shep.PromptBuilder do
  @moduledoc "Composes base prompt + task template into a full agent prompt."

  @base_file "base.md"

  @doc """
  Compose base + task template, leaving every `{{KEY}}` (including
  `{{TASK_BODY}}`) as a placeholder. The result is trusted text only —
  no issue-supplied content is spliced in yet — so it is safe to run
  through `Shep.Prompt.expand/3`, whose `bash -c` shell blocks then see
  only `priv/prompts/` templates. Substitution happens afterward in
  `build_expanded/2`. See #30: issue-body prose must never reach `bash -c`.
  """
  @spec build(Shep.Task.t()) :: String.t()
  def build(%Shep.Task{} = task) do
    base = read_template(@base_file)
    template = load_task_template(task.type)

    String.replace(base, "{{TASK_BODY}}", template <> "\n\n{{TASK_BODY}}")
  end

  @doc """
  Build a task's final prompt: expand the trusted template's shell blocks
  in `cwd`, then substitute the raw issue body and `prompt_args` as plain
  text. Key substitution runs after shell expansion, so neither the body
  nor any arg value is ever executed — it can only appear literally.
  """
  @spec build_expanded(Shep.Task.t(), String.t()) :: String.t()
  def build_expanded(%Shep.Task{} = task, cwd) when is_binary(cwd) do
    args = Map.put(task.prompt_args || %{}, "TASK_BODY", task.prompt || "")

    task
    |> build()
    |> Shep.Prompt.expand(args, cwd)
  end

  @doc "List available template names."
  @spec list_templates() :: [String.t()]
  def list_templates do
    templates_dir = Path.join(prompts_dir(), "templates")

    case File.ls(templates_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&String.trim_trailing(&1, ".md"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc false
  def prompts_dir do
    Application.app_dir(:shep, "priv/prompts")
  end

  defp load_task_template(nil), do: read_template("templates/custom.md")

  defp load_task_template(type) when is_binary(type) do
    path = "templates/#{type}.md"

    case read_template_safe(path) do
      {:ok, content} -> content
      :error -> read_template("templates/custom.md")
    end
  end

  defp read_template(relative_path) do
    path = Path.join(prompts_dir(), relative_path)

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp read_template_safe(relative_path) do
    path = Path.join(prompts_dir(), relative_path)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> :error
    end
  end
end
