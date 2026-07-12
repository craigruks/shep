defmodule Shep.PromptTest do
  use ExUnit.Case, async: true

  alias Shep.Prompt

  @cwd System.tmp_dir!()

  describe "expand/3: key substitution" do
    test "replaces {{KEY}} with value" do
      assert "hello world" == Prompt.expand("hello {{NAME}}", %{"NAME" => "world"}, @cwd)
    end

    test "leaves unmatched keys as-is" do
      assert "hello {{MISSING}}" == Prompt.expand("hello {{MISSING}}", %{}, @cwd)
    end

    test "replaces multiple keys" do
      template = "{{A}} and {{B}}"
      args = %{"A" => "foo", "B" => "bar"}
      assert "foo and bar" == Prompt.expand(template, args, @cwd)
    end

    test "handles empty template" do
      assert "" == Prompt.expand("", %{}, @cwd)
    end
  end

  describe "expand/3: shell expansion" do
    test "expands !`echo hello`" do
      result = Prompt.expand("say !`echo hello`", %{}, @cwd)
      assert String.contains?(result, "hello")
    end

    test "expands multiple shell blocks" do
      result = Prompt.expand("!`echo a` and !`echo b`", %{}, @cwd)
      assert String.contains?(result, "a")
      assert String.contains?(result, "b")
    end

    test "handles command failure gracefully" do
      result = Prompt.expand("!`exit 1`", %{}, @cwd)
      assert is_binary(result)
    end
  end

  describe "expand/3: combined" do
    test "shell + key substitution" do
      result = Prompt.expand("!`echo hi` {{NAME}}", %{"NAME" => "world"}, @cwd)
      assert String.contains?(result, "hi")
      assert String.contains?(result, "world")
    end
  end
end
