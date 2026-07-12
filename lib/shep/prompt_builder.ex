defmodule Shep.PromptBuilder do
  @moduledoc "Composes base prompt + task template into a full agent prompt."

  @base_file "base.md"

  @template_timeouts %{
    "lint-fix" => 1_200_000,
    "transpiler-fix" => 1_200_000,
    "test-fix" => 1_200_000,
    "dependency-update" => 1_200_000,
    "docs-update" => 600_000,
    "custom" => 2_700_000
  }

  @doc "Build a full prompt for a task. Returns `{prompt, suggested_timeout_ms}`."
  @spec build(Shep.Task.t()) :: {String.t(), non_neg_integer()}
  def build(%Shep.Task{} = task) do
    base = read_template(@base_file)
    template = load_task_template(task.type)
    body = task.prompt || ""

    full =
      base
      |> String.replace("{{TASK_BODY}}", template <> "\n\n" <> body)
      |> inject_args(task.prompt_args)

    timeout = Map.get(@template_timeouts, task.type || "custom", 1_200_000)
    {full, timeout}
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

  defp inject_args(prompt, args) when is_map(args) do
    Enum.reduce(args, prompt, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", value)
    end)
  end
end
