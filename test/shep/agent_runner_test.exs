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

defmodule Shep.AgentRunnerPortKillTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner

  defp sleeper_script do
    dir = Path.join(System.tmp_dir!(), "shep_kill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "sleeper.sh")
    File.write!(path, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(path, 0o755)
    path
  end

  test "silence timeout closes the port and SIGKILLs the OS process" do
    script = sleeper_script()

    port =
      Port.open({:spawn_executable, script}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        :stderr_to_stdout
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    assert {_output, 137} = AgentRunner.collect_port_output_for_test(port, "kill-1", self(), 50)
    assert wait_until_dead(os_pid), "OS process #{os_pid} survived the timeout kill"
  end

  # kill -0 succeeds on a zombie until the VM reaps it, so poll briefly.
  defp wait_until_dead(os_pid, tries \\ 100) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} when tries > 0 ->
        Process.sleep(20)
        wait_until_dead(os_pid, tries - 1)

      {_, exit_code} ->
        exit_code != 0
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

defmodule Shep.AgentRunnerCreatePRTest do
  # Installs the :gh_runner app env, so no concurrent cases.
  use ExUnit.Case, async: false

  alias Shep.AgentRunner
  alias Shep.Completion.Complete

  setup do
    start_supervised!({Shep.Tracker.Memory, tasks: []})
    Application.put_env(:shep, :tracker_adapter, Shep.Tracker.Memory)

    on_exit(fn ->
      Application.delete_env(:shep, :tracker_adapter)
      Application.delete_env(:shep, :gh_runner)
    end)

    :ok
  end

  defp clean_committed_worktree(branch) do
    n = System.unique_integer([:positive])
    bare = Path.join(System.tmp_dir!(), "shep_pr_bare_#{n}.git")
    wt = Path.join(System.tmp_dir!(), "shep_pr_wt_#{n}")
    File.mkdir_p!(wt)

    on_exit(fn ->
      File.rm_rf!(bare)
      File.rm_rf!(wt)
    end)

    {_, 0} = System.cmd("git", ["init", "-q", "--bare", bare])
    {_, 0} = System.cmd("git", ["-C", wt, "init", "-q", "-b", branch])
    {_, 0} = System.cmd("git", ["-C", wt, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", wt, "config", "user.name", "Test"])
    {_, 0} = System.cmd("git", ["-C", wt, "commit", "-q", "--allow-empty", "-m", "work"])
    {_, 0} = System.cmd("git", ["-C", wt, "remote", "add", "origin", bare])
    wt
  end

  defp config, do: %{"tracker" => %{"repo" => "org/repo"}, "staging" => %{"pr_target" => "main"}}

  test "a missing PR label never sinks the PR creation" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn
      ["pr", "create" | _] = args ->
        send(test_pid, {:gh, args})
        {:ok, "https://github.com/org/repo/pull/9"}

      ["pr", "edit" | _] = args ->
        send(test_pid, {:gh, args})
        {:error, "could not add label: 'agent: claude-code' not found"}
    end)

    wt = clean_committed_worktree("shep/pr-1")
    task = %Shep.Task{id: "pr-1", branch: "shep/pr-1", prompt: "p"}

    assert {:ok, "https://github.com/org/repo/pull/9"} =
             AgentRunner.create_pr_for_test(%Complete{summary: "did it"}, task, wt, config())

    assert_received {:gh, ["pr", "create" | create_args]}
    refute "--label" in create_args
    assert_received {:gh, ["pr", "edit" | edit_args]}
    assert "agent: claude-code" == List.last(edit_args)
    assert "pr-created" == Shep.Tracker.Memory.get_status("pr-1")
  end

  test "no_merge tasks request the shep:no-merge label" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn
      ["pr", "create" | _] -> {:ok, "https://github.com/org/repo/pull/10"}
      ["pr", "edit" | _] = args -> send(test_pid, {:gh, args}) && {:ok, ""}
    end)

    wt = clean_committed_worktree("shep/pr-2")
    task = %Shep.Task{id: "pr-2", branch: "shep/pr-2", prompt: "p", no_merge: true}

    assert {:ok, _url} =
             AgentRunner.create_pr_for_test(%Complete{summary: "did it"}, task, wt, config())

    assert_received {:gh, edit_args}
    assert "shep:no-merge" == List.last(edit_args)
  end
end
