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

defmodule Shep.AgentRunnerDemoTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner

  describe "demo tasks" do
    test "never push or create a PR, even on a clean Complete" do
      task = %Shep.Task{id: "demo-t", branch: "shep/demo-t", prompt: "x", demo: true}
      completion = %Shep.Completion.Complete{summary: "done"}

      assert :none == AgentRunner.create_pr_for_test(completion, task, "/nonexistent", %{})
    end
  end
end

defmodule Shep.AgentRunnerVerifyLoopTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner
  alias Shep.Completion.{Complete, Failed}

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "shep_verify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp stub_agent(dir, body) do
    path = Path.join(dir, "stub_agent.sh")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  defp config(verify, agent_cmd, fixes) do
    %{
      "goal" => %{"verify" => verify, "verify_fixes" => fixes},
      "agent" => %{"command" => agent_cmd}
    }
  end

  test "green verify on the first try returns the completion unchanged" do
    dir = tmp_dir()
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v1", branch: "b", prompt: "p"}

    assert ^final =
             AgentRunner.run_verify_loop_for_test(
               final,
               task,
               dir,
               config("true", "unused", 2),
               self()
             )
  end

  test "red verify dispatches a fix turn, then re-verifies green" do
    dir = tmp_dir()
    agent = stub_agent(dir, "touch fixed.marker\necho applied a fix")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v2", branch: "b", prompt: "p"}

    result =
      AgentRunner.run_verify_loop_for_test(
        final,
        task,
        dir,
        config("test -f fixed.marker", agent, 2),
        self()
      )

    assert %Complete{} = result
    assert File.exists?(Path.join(dir, "fixed.marker"))
    assert_received {:agent_output, "v2", _line}
  end

  test "exhausted fix attempts yield Failed with the verify tail" do
    dir = tmp_dir()
    agent = stub_agent(dir, "echo still broken")
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v3", branch: "b", prompt: "p"}

    assert %Failed{reason: reason, recoverable: false} =
             AgentRunner.run_verify_loop_for_test(
               final,
               task,
               dir,
               config("echo nope; false", agent, 2),
               self()
             )

    assert reason =~ "verify failed after 2 fix attempts"
    assert reason =~ "nope"
  end

  test "demo tasks skip the verify loop entirely" do
    dir = tmp_dir()
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v4", branch: "b", prompt: "p", demo: true}

    assert ^final =
             AgentRunner.run_verify_loop_for_test(
               final,
               task,
               dir,
               config("false", "unused", 2),
               self()
             )
  end

  test "codex tasks skip the verify loop (fix turns are claude-only)" do
    dir = tmp_dir()
    final = %Complete{summary: "done"}
    task = %Shep.Task{id: "v5", branch: "b", prompt: "p", agent: :codex}

    assert ^final =
             AgentRunner.run_verify_loop_for_test(
               final,
               task,
               dir,
               config("false", "unused", 2),
               self()
             )
  end

  test "a Failed completion passes through without running verify" do
    dir = tmp_dir()
    final = %Failed{reason: "agent gave up", recoverable: false}
    task = %Shep.Task{id: "v6", branch: "b", prompt: "p"}

    assert ^final =
             AgentRunner.run_verify_loop_for_test(
               final,
               task,
               dir,
               config("false", "unused", 2),
               self()
             )
  end
end

defmodule Shep.AgentRunnerResolveExecutableTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner

  test "bare names resolve via PATH" do
    assert AgentRunner.resolve_executable("sh") =~ "sh"
  end

  test "existing paths resolve to absolute" do
    assert AgentRunner.resolve_executable("/bin/sh") == "/bin/sh"
  end

  test "missing bare name and missing path both return nil" do
    assert AgentRunner.resolve_executable("shep-no-such-cmd-xyz") == nil
    assert AgentRunner.resolve_executable("./no/such/path.sh") == nil
  end
end
