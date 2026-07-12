defmodule Shep.AgentRunner.ClaudeTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner.Claude

  describe "build_args/2" do
    test "headless stream-json invocation with a named session" do
      args = Claude.build_args("do the thing", "42")
      assert "--print" in args
      assert "--dangerously-skip-permissions" in args
      of = Enum.find_index(args, &(&1 == "--output-format"))
      assert Enum.at(args, of + 1) == "stream-json"
      name = Enum.find_index(args, &(&1 == "--name"))
      assert Enum.at(args, name + 1) == "shep-42"
      assert ["-p", "do the thing"] == Enum.take(args, -2)
    end
  end

  describe "build_resume_args/1" do
    test "continues the named session without a prompt" do
      args = Claude.build_resume_args("42")
      assert "--continue" in args
      assert "shep-42" in args
      refute "-p" in args
    end
  end

  describe "build_continue_args/2" do
    test "continues the session with the fix prompt appended" do
      args = Claude.build_continue_args("fix it", "42")
      assert "--continue" in args
      assert "shep-42" in args
      assert ["-p", "fix it"] == Enum.take(args, -2)
    end
  end

  describe "extract_text/1" do
    test "pulls text blocks from assistant stream-json lines" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "hello"},
              %{"type" => "tool_use", "name" => "Bash"},
              %{"type" => "text", "text" => "world"}
            ]
          }
        })

      assert "hello\nworld" == Claude.extract_text(line)
    end

    test "pulls the result field from result lines" do
      line = Jason.encode!(%{"type" => "result", "result" => "all done"})
      assert "all done" == Claude.extract_text(line)
    end

    test "non-JSON lines pass through untouched" do
      assert "plain output" == Claude.extract_text("plain output")
    end
  end

  describe "model selection" do
    test "nil model adds no flag" do
      refute "--model" in Claude.build_args("p", "1")
      refute "--model" in Claude.build_resume_args("1")
    end

    test "a configured model is passed on fresh, resume, and continue turns" do
      for args <- [
            Claude.build_args("p", "1", "opus"),
            Claude.build_resume_args("1", "opus"),
            Claude.build_continue_args("fix", "1", "opus")
          ] do
        i = Enum.find_index(args, &(&1 == "--model"))
        assert i, "missing --model in #{inspect(args)}"
        assert Enum.at(args, i + 1) == "opus"
      end
    end

    test "the prompt stays last on continue turns with a model" do
      assert ["-p", "fix"] == Enum.take(Claude.build_continue_args("fix", "1", "opus"), -2)
    end
  end

  test "session_name/1 is shep-<id>" do
    assert "shep-7" == Claude.session_name("7")
  end
end
