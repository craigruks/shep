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
end
