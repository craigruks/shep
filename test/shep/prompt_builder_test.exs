defmodule Shep.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias Shep.PromptBuilder

  describe "build/1" do
    test "returns the composed prompt" do
      task = %Shep.Task{id: "1", branch: "test/1", prompt: "fix it", type: "lint-fix"}
      prompt = PromptBuilder.build(task)
      assert is_binary(prompt)
      assert prompt =~ "fix it"
    end

    test "nil type falls back to the custom template" do
      task = %Shep.Task{id: "3", branch: "test/3", prompt: "do thing", type: nil}
      assert PromptBuilder.build(task) =~ "do thing"
    end

    test "injects prompt_args" do
      task = %Shep.Task{
        id: "4",
        branch: "test/4",
        prompt: "fix issue {{ISSUE_NUMBER}}",
        prompt_args: %{"ISSUE_NUMBER" => "42"}
      }

      prompt = PromptBuilder.build(task)
      assert prompt =~ "fix issue 42"
    end
  end

  describe "prompts_dir/0" do
    test "resolves to absolute path regardless of CWD" do
      dir = PromptBuilder.prompts_dir()
      assert String.starts_with?(dir, "/"), "prompts_dir must be absolute, got: #{dir}"
    end

    test "points to a directory containing base.md" do
      base = Path.join(PromptBuilder.prompts_dir(), "base.md")
      assert File.exists?(base), "base.md must exist at #{base}"
    end

    test "build produces non-empty prompt from any CWD" do
      task = %Shep.Task{id: "cwd-test", branch: "test/cwd", prompt: "hello", type: "lint-fix"}
      prompt = PromptBuilder.build(task)
      assert byte_size(prompt) > 20, "prompt should not be empty (silent fallback = broken path)"
    end
  end

  describe "list_templates/0" do
    test "returns available template names" do
      templates = PromptBuilder.list_templates()
      assert is_list(templates)
      assert "custom" in templates
      assert "lint-fix" in templates
      assert "test-fix" in templates
    end

    test "does not include file extensions" do
      templates = PromptBuilder.list_templates()
      refute Enum.any?(templates, &String.ends_with?(&1, ".md"))
    end
  end
end
