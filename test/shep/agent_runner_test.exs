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
    test "returns exec command with the prompt as a positional arg" do
      args = AgentRunner.Codex.build_args("fix lint", "1")
      assert args == ["exec", "--", "fix lint"]
    end
  end
end

defmodule Shep.AgentRunnerModelTest do
  # Runs a stub agent that records its own argv, so model selection is
  # asserted on the command line the CLI actually receives.
  use ExUnit.Case, async: true

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "shep_model_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp recording_agent(dir) do
    path = Path.join(dir, "stub_agent.sh")
    File.write!(path, "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\" >> argv.txt; done\n")
    File.chmod!(path, 0o755)
    path
  end

  defp argv_after_fix_turn(dir, task, config_model) do
    agent = recording_agent(dir)
    config = %{"agent" => %{"command" => agent, "model" => config_model}}
    Shep.AgentRunner.fix_turn("go", Shep.Workspace.local(dir), task, config, self())
    dir |> Path.join("argv.txt") |> File.read!() |> String.split("\n", trim: true)
  end

  defp model_flag(argv) do
    case Enum.find_index(argv, &(&1 == "--model")) do
      nil -> nil
      i -> Enum.at(argv, i + 1)
    end
  end

  test "a task model overrides the configured model" do
    dir = tmp_dir()
    task = %Shep.Task{id: "m1", branch: "b", prompt: "p", model: "sonnet"}

    assert "sonnet" == argv_after_fix_turn(dir, task, "opus") |> model_flag()
  end

  test "without a task model the configured model is used" do
    dir = tmp_dir()
    task = %Shep.Task{id: "m2", branch: "b", prompt: "p"}

    assert "opus" == argv_after_fix_turn(dir, task, "opus") |> model_flag()
  end

  test "no task model and no configured model passes no --model flag" do
    dir = tmp_dir()
    task = %Shep.Task{id: "m3", branch: "b", prompt: "p"}

    assert nil == argv_after_fix_turn(dir, task, nil) |> model_flag()
  end

  describe "model_for/2" do
    @config %{"agent" => %{"model" => "opus"}}

    test "a codex task does not inherit the claude-shaped agent.model default" do
      task = %Shep.Task{id: "m4", branch: "b", prompt: "p", agent: :codex}
      assert nil == Shep.AgentRunner.model_for(task, @config)
    end

    test "a codex task still honours its own label override" do
      task = %Shep.Task{id: "m5", branch: "b", prompt: "p", agent: :codex, model: "gpt-5-codex"}
      assert "gpt-5-codex" == Shep.AgentRunner.model_for(task, @config)
    end
  end
end
