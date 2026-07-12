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
