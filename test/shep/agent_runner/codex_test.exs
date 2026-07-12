defmodule Shep.AgentRunner.CodexTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner.Codex

  test "build_args/2 is a plain exec with the prompt" do
    assert ["exec", "-p", "do the thing"] == Codex.build_args("do the thing", "42")
  end

  test "build_resume_args/1 resumes the last session" do
    assert ["resume", "--last"] == Codex.build_resume_args("42")
  end

  test "extract_text/1 passes lines through untouched" do
    assert "raw" == Codex.extract_text("raw")
  end

  test "session_name/1 matches the claude convention" do
    assert "shep-7" == Codex.session_name("7")
  end
end
