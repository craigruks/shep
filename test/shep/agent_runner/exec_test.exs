defmodule Shep.AgentRunner.ExecTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner.Exec

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

      completion = Exec.parse_completion_from_line_for_test(json_line)

      assert %Shep.Completion.Complete{summary: "fixed lint"} = completion
    end

    test "extracts completion from result JSON" do
      json_line =
        Jason.encode!(%{
          "type" => "result",
          "result" =>
            ~s|<completion>{"type":"failed","reason":"cannot fix","recoverable":false}</completion>|
        })

      completion = Exec.parse_completion_from_line_for_test(json_line)
      assert %Shep.Completion.Failed{reason: "cannot fix"} = completion
    end

    test "returns nil for lines without completion" do
      json_line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "working on it..."}]}
        })

      assert nil == Exec.parse_completion_from_line_for_test(json_line)
    end

    test "handles non-JSON lines gracefully" do
      assert nil == Exec.parse_completion_from_line_for_test("not json at all")
    end
  end

  describe "resolve_executable/1" do
    test "bare names resolve via PATH" do
      assert Exec.resolve_executable("sh") =~ "sh"
    end

    test "existing paths resolve to absolute" do
      assert Exec.resolve_executable("/bin/sh") == "/bin/sh"
    end

    test "missing bare name and missing path both return nil" do
      assert Exec.resolve_executable("shep-no-such-cmd-xyz") == nil
      assert Exec.resolve_executable("./no/such/path.sh") == nil
    end
  end

  describe "run/6" do
    setup do
      dir = Path.join(System.tmp_dir!(), "shep_exec_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    # Regression for #55: the BEAM keeps the spawned child's stdin pipe
    # open, so an agent that reads stdin (Codex always does) blocked until
    # the idle timeout. A short timeout keeps a regression fast.
    test "an agent that reads stdin sees EOF instead of blocking", %{dir: dir} do
      exe = stub_agent(dir, "cat > /dev/null\necho done\n")

      result = Exec.run(exe, [], dir, task(), self(), 3_000)

      assert result.exit_code == 0
      assert result.stdout == "done"
    end

    test "the agent's own exit code surfaces, not a wrapper's", %{dir: dir} do
      exe = stub_agent(dir, "echo bye\nexit 42\n")

      assert %{exit_code: 42, stdout: "bye"} = Exec.run(exe, [], dir, task(), self(), 3_000)
    end

    test "args arrive as argv, unsplit and unexpanded", %{dir: dir} do
      exe = stub_agent(dir, ~S|for a in "$@"; do echo "[$a]"; done| <> "\n")
      args = ["--prompt", "two words; echo pwned", "$HOME *"]

      result = Exec.run(exe, args, dir, task(), self(), 3_000)

      assert result.stdout == ~s|[--prompt]\n[two words; echo pwned]\n[$HOME *]|
    end

    test "the agent runs in the given cwd and streams lines to the caller", %{dir: dir} do
      exe = stub_agent(dir, "pwd\n")

      result = Exec.run(exe, [], dir, task(), self(), 3_000)

      {physical_dir, 0} = System.cmd("pwd", [], cd: dir)
      assert result.stdout == String.trim(physical_dir)
      assert_received {:agent_output, "exec-1", _line}
    end

    # The shell wrapper must exec away, so the pid the port kills is the
    # agent's own. The agent reports that pid on stdout before going quiet.
    test "the idle timeout kills the agent process itself", %{dir: dir} do
      exe = stub_agent(dir, "echo $$\nexec sleep 30\n")

      assert %{exit_code: 137, stdout: os_pid} = Exec.run(exe, [], dir, task(), self(), 200)
      assert dead?(os_pid), "agent process #{os_pid} survived the timeout kill"
    end
  end

  defp stub_agent(dir, body) do
    path = Path.join(dir, "agent.sh")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp task, do: %Shep.Task{id: "exec-1", branch: "b", prompt: "p"}

  # kill -0 succeeds on a zombie until the VM reaps it, so poll briefly.
  defp dead?(os_pid, tries \\ 100) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_, 0} when tries > 0 ->
        Process.sleep(20)
        dead?(os_pid, tries - 1)

      {_, exit_code} ->
        exit_code != 0
    end
  end
end

defmodule Shep.AgentRunner.ExecPortKillTest do
  use ExUnit.Case, async: true

  alias Shep.AgentRunner.Exec

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

    assert {_output, 137} = Exec.collect_port_output_for_test(port, "kill-1", self(), 50)
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
