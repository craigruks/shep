defmodule Shep.GoalTest do
  use ExUnit.Case, async: true

  alias Shep.Goal

  describe "run_verify/2" do
    test "passing command returns ok with output" do
      assert {:ok, out} = Goal.run_verify("echo all green", System.tmp_dir!())
      assert out =~ "all green"
    end

    test "failing command returns error with output" do
      assert {:error, out} = Goal.run_verify("echo boom; exit 1", System.tmp_dir!())
      assert out =~ "boom"
    end
  end

  describe "tail/2" do
    test "short strings pass through" do
      assert Goal.tail("abc", 10) == "abc"
    end

    test "long strings keep only the last bytes" do
      assert Goal.tail(String.duplicate("x", 100) <> "END", 3) == "END"
    end
  end

  describe "fix_prompt/5" do
    test "verify prompt carries attempt count, command, and output" do
      p = Goal.fix_prompt(:verify, 1, 2, "test failed: foo", "mix quality")
      assert p =~ "attempt 1 of 2"
      assert p =~ "mix quality"
      assert p =~ "test failed: foo"
      assert p =~ "Do NOT push"
    end

    test "ci prompt carries logs and the no-push rule" do
      p = Goal.fix_prompt(:ci, 2, 2, "### quality\nassertion failed", nil)
      assert p =~ "attempt 2 of 2"
      assert p =~ "assertion failed"
      assert p =~ "Do NOT push"
    end
  end

  describe "config schema goal defaults" do
    test "goal and workspace.repo defaults are present" do
      {:ok, config} = Shep.Config.Schema.validate(%{})
      assert get_in(config, ["goal", "verify"]) == nil
      assert get_in(config, ["goal", "verify_fixes"]) == 2
      assert get_in(config, ["goal", "ci_fixes"]) == 2
      assert get_in(config, ["workspace", "repo"]) == "."
    end

    test "workspace.repo expands tilde" do
      {:ok, config} = Shep.Config.Schema.validate(%{"workspace" => %{"repo" => "~/code/x"}})
      assert get_in(config, ["workspace", "repo"]) == Path.join(System.user_home!(), "code/x")
    end
  end

  describe "Claude fix-turn args" do
    test "build_continue_args continues the session with the prompt" do
      args = Shep.AgentRunner.Claude.build_continue_args("fix it", "42")
      assert "--continue" in args
      assert "shep-42" in args
      assert List.last(args) == "fix it"
      assert Enum.at(args, -2) == "-p"
    end
  end

  describe "CIWatch.run_id_from_link/1" do
    test "extracts run id from a checks link" do
      link = "https://github.com/o/r/actions/runs/1234567/job/89"
      assert Shep.CIWatch.run_id_from_link(link) == "1234567"
    end

    test "nil-safe on garbage" do
      assert Shep.CIWatch.run_id_from_link("https://example.com") == nil
      assert Shep.CIWatch.run_id_from_link(nil) == nil
    end
  end
end
