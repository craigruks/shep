defmodule Shep.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner

  describe "Claude.build_args/2" do
    test "includes --verbose with --output-format stream-json" do
      args = AgentRunner.Claude.build_args("fix the lint", "1")
      assert "--verbose" in args
      assert "--output-format" in args
      assert "stream-json" in args
    end

    test "--verbose appears before --output-format" do
      args = AgentRunner.Claude.build_args("test prompt", "1")
      verbose_idx = Enum.find_index(args, &(&1 == "--verbose"))
      format_idx = Enum.find_index(args, &(&1 == "--output-format"))

      assert verbose_idx < format_idx,
             "--verbose must precede --output-format (stream-json requires it)"
    end

    test "includes --print flag" do
      args = AgentRunner.Claude.build_args("hello", "1")
      assert "--print" in args
    end

    test "prompt is passed via -p flag" do
      prompt = "fix all the biome violations"
      args = AgentRunner.Claude.build_args(prompt, "42")
      p_idx = Enum.find_index(args, &(&1 == "-p"))
      assert p_idx != nil
      assert Enum.at(args, p_idx + 1) == prompt
    end

    test "includes --name with session name" do
      args = AgentRunner.Claude.build_args("hello", "99")
      name_idx = Enum.find_index(args, &(&1 == "--name"))
      assert name_idx != nil
      assert Enum.at(args, name_idx + 1) == "shep-99"
    end
  end

  describe "Claude.build_resume_args/1" do
    test "includes --continue flag" do
      args = AgentRunner.Claude.build_resume_args("42")
      assert "--continue" in args
    end

    test "includes --name with session name" do
      args = AgentRunner.Claude.build_resume_args("42")
      name_idx = Enum.find_index(args, &(&1 == "--name"))
      assert name_idx != nil
      assert Enum.at(args, name_idx + 1) == "shep-42"
    end

    test "does not include -p flag" do
      args = AgentRunner.Claude.build_resume_args("42")
      refute "-p" in args
    end
  end

  describe "Codex.build_args/2" do
    test "returns exec command with prompt" do
      args = AgentRunner.Codex.build_args("fix lint", "1")
      assert args == ["exec", "-p", "fix lint"]
    end
  end

  describe "completion parsing from stream-json" do
    test "extracts completion from assistant message JSON" do
      json_line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "text",
                "text" =>
                  ~s|Done.\n<completion>{"type":"complete","summary":"fixed lint","verify":["biome passes"]}</completion>|
              }
            ]
          }
        })

      completion =
        json_line
        |> then(&AgentRunner.parse_completion_from_line_for_test/1)

      assert %Shep.Completion.Complete{summary: "fixed lint"} = completion
    end

    test "extracts completion from result JSON" do
      json_line =
        Jason.encode!(%{
          "type" => "result",
          "result" =>
            ~s|<completion>{"type":"failed","reason":"cannot fix","recoverable":false}</completion>|
        })

      completion = AgentRunner.parse_completion_from_line_for_test(json_line)
      assert %Shep.Completion.Failed{reason: "cannot fix"} = completion
    end

    test "returns nil for lines without completion" do
      json_line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "working on it..."}]}
        })

      assert nil == AgentRunner.parse_completion_from_line_for_test(json_line)
    end

    test "handles non-JSON lines gracefully" do
      assert nil == AgentRunner.parse_completion_from_line_for_test("not json at all")
    end
  end
end
