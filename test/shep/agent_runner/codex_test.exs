defmodule Shep.AgentRunner.CodexTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner.Codex

  test "build_args/2 passes the prompt positionally, after --" do
    # `-p` is Codex's --profile: passing the prompt there makes the CLI
    # reject it as a profile name and read the real prompt from stdin.
    assert ["exec", "--", "do the thing"] == Codex.build_args("do the thing", "42")
  end

  test "build_args/3 passes a model through before the prompt" do
    assert ["exec", "--model", "gpt-5-codex", "--", "do it"] ==
             Codex.build_args("do it", "42", "gpt-5-codex")
  end

  test "build_resume_args/1 resumes the last session headlessly" do
    # Bare `codex resume` is the interactive picker; `codex exec resume`
    # is the non-interactive form a Port can drive.
    assert ["exec", "resume", "--last"] == Codex.build_resume_args("42")
  end

  test "build_resume_args/2 carries the model into the resumed session" do
    assert ["exec", "resume", "--last", "--model", "gpt-5-codex"] ==
             Codex.build_resume_args("42", "gpt-5-codex")
  end

  test "extract_text/1 passes lines through untouched" do
    assert "raw" == Codex.extract_text("raw")
  end

  test "session_name/1 matches the claude convention" do
    assert "shep-7" == Codex.session_name("7")
  end
end
