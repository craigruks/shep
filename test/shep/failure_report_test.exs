defmodule Shep.FailureReportTest do
  use ExUnit.Case, async: true

  alias Shep.FailureReport

  describe "redact/1" do
    test "token shapes become [REDACTED]" do
      for token <- [
            "ghp_" <> String.duplicate("a1B2", 9),
            "gho_" <> String.duplicate("c3D4", 9),
            "github_pat_11ABCDEFG0" <> String.duplicate("x_Y9", 12),
            "sk-ant-api03-" <> String.duplicate("Qw3_", 10),
            "sk-proj-" <> String.duplicate("Er5t", 8),
            "xoxb-1234567890-0987654321-" <> String.duplicate("aB", 12)
          ] do
        redacted = FailureReport.redact("token=#{token} end")
        assert redacted == "token=[REDACTED] end", "leaked: #{token}"
      end
    end

    test "long hex runs become [REDACTED]" do
      assert FailureReport.redact("secret " <> String.duplicate("deadbeef", 5)) ==
               "secret [REDACTED]"
    end

    test "long high-entropy base64 runs become [REDACTED]" do
      key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      assert FailureReport.redact("AWS_SECRET=#{key}") == "AWS_SECRET=[REDACTED]"
    end

    test "ordinary log text survives: paths, short SHAs, identifiers, prose" do
      text = """
      /home/runner/work/shep/shep/_build/test/lib/shep/consolidated
      test/shep/orchestrator/tidy_schedule_test_something_long_name.exs:42
      HEAD is now at 477351e Merge pull request #100
      SHEP_WORKFLOW_PATH_SOMETHING_LONG_ENV_VAR_NAME_HERE
      the task-runner failed: sk- prefix alone is fine
      """

      assert FailureReport.redact(text) == text
    end
  end

  describe "tail/1" do
    test "keeps only the last 30 lines" do
      output = Enum.map_join(1..100, "\n", &"line #{&1}")
      lines = output |> FailureReport.tail() |> String.split("\n")

      assert length(lines) == 30
      assert hd(lines) == "line 71"
      assert List.last(lines) == "line 100"
    end

    test "caps the tail at 4000 characters, keeping the end" do
      output = String.duplicate("x ", 3_000) <> "THE END"
      tail = FailureReport.tail(output)

      assert String.length(tail) == 4_000
      assert String.ends_with?(tail, "THE END")
    end

    test "nil and blank output yield an empty tail" do
      assert FailureReport.tail(nil) == ""
      assert FailureReport.tail("\n  \n") == ""
    end
  end

  describe "body/2" do
    test "collapses the redacted tail into a fenced details block" do
      body = FailureReport.body("verify failed", "boom\nghp_#{String.duplicate("Z", 36)}")

      assert body =~ ~r/\AGoal not reached: verify failed\n\n<details>/
      assert body =~ "```\nboom\n[REDACTED]\n```"
      assert String.ends_with?(body, "</details>")
    end

    test "output containing a code fence gets a longer fence" do
      body = FailureReport.body("r", "before\n```\nafter")
      assert body =~ "````\nbefore\n```\nafter\n````"
    end

    test "the reason is redacted too" do
      token = "gho_" <> String.duplicate("k8", 20)
      refute FailureReport.body("push failed for #{token}", nil) =~ token
    end

    test "no output, no details block" do
      assert FailureReport.body("CI never verified the PR", nil) ==
               "Goal not reached: CI never verified the PR"
    end
  end
end

defmodule Shep.FailureReportPostTest do
  # Installs the global :tracker_adapter.
  use ExUnit.Case, async: false

  alias Shep.Tracker.Memory

  setup do
    start_supervised!({Memory, tasks: []})
    Application.put_env(:shep, :tracker_adapter, Memory)
    on_exit(fn -> Application.delete_env(:shep, :tracker_adapter) end)
    :ok
  end

  test "post/3 labels the issue failed and never puts a fake token in the comment" do
    token = "ghp_" <> String.duplicate("Fake7Tok", 5)
    task = %Shep.Task{id: "fr-1", branch: "b", prompt: "p"}

    assert :ok = Shep.FailureReport.post(task, "agent failed: exit code 1", "GH_TOKEN=#{token}")

    assert "failed" == Memory.get_status("fr-1")
    assert [comment] = Memory.get_comments("fr-1")
    assert comment =~ "GH_TOKEN=[REDACTED]"
    refute comment =~ token
    refute comment =~ "Fake7Tok"
  end
end
