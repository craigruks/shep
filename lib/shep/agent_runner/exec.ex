defmodule Shep.AgentRunner.Exec do
  @moduledoc """
  Process execution boundary: resolve the agent executable, run it under
  a line-buffered Port, stream stdout to the orchestrator, and enforce
  the idle timeout with an explicit close + SIGKILL so no agent lingers
  as a zombie. Completion signals are parsed out of the streamed lines.
  """

  require Logger

  @max_line_length 65_536

  # The BEAM hands a spawned port an stdin pipe it holds open forever.
  # A CLI that reads stdin when it is not a TTY (Codex does) then blocks
  # on an EOF that never comes. Spawning through `sh -c` lets us redirect
  # stdin from /dev/null; `exec` replaces the shell, so the port's os_pid
  # and exit status are the agent's own, not a wrapper's.
  @shell "/bin/sh"
  @exec_with_closed_stdin ~S|exec "$0" "$@" </dev/null|

  @doc "Resolve an agent command: bare names via PATH, paths relative to cwd."
  @spec resolve_executable(String.t()) :: String.t() | nil
  def resolve_executable(cmd) do
    if String.contains?(cmd, "/") do
      path = Path.expand(cmd)
      if File.exists?(path), do: path, else: nil
    else
      System.find_executable(cmd)
    end
  end

  @doc "Build the IterationResult for an agent command that could not be resolved."
  @spec executable_not_found(String.t()) :: Shep.IterationResult.t()
  def executable_not_found(agent_cmd) do
    reason = "agent command not found: #{agent_cmd}"
    Logger.error(reason)

    %Shep.IterationResult{
      stdout: "",
      stderr: reason,
      exit_code: 127,
      completion: %Shep.Completion.Failed{reason: reason, recoverable: false},
      duration_ms: 0
    }
  end

  @doc "Run one agent turn under a Port, returning its IterationResult."
  @spec run(String.t(), [String.t()], String.t(), Shep.Task.t(), pid(), non_neg_integer()) ::
          Shep.IterationResult.t()
  def run(exe, args, cwd, task, orchestrator_pid, idle_ms) do
    started_at = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, @shell}, [
        :binary,
        :exit_status,
        {:line, @max_line_length},
        :stderr_to_stdout,
        {:cd, cwd},
        {:env, Shep.Env.for_port()},
        {:args, ["-c", @exec_with_closed_stdin, exe | args]}
      ])

    report_os_pid(port, task.id, orchestrator_pid)

    {stdout, exit_code} = collect_output(port, task.id, orchestrator_pid, idle_ms)
    duration = System.monotonic_time(:millisecond) - started_at

    completion =
      stdout
      |> String.split("\n")
      |> Enum.find_value(&parse_completion_from_line(&1, task.agent))

    %Shep.IterationResult{
      stdout: stdout,
      stderr: "",
      exit_code: exit_code,
      completion: completion,
      duration_ms: duration
    }
  end

  @doc "Map an agent tag to its CLI adapter module."
  @spec agent_module(:claude | :codex) :: module()
  def agent_module(:claude), do: Shep.AgentRunner.Claude
  def agent_module(:codex), do: Shep.AgentRunner.Codex

  @doc false
  def parse_completion_from_line_for_test(line), do: parse_completion_from_line(line, :claude)

  defp parse_completion_from_line(line, agent) do
    text = agent_module(agent).extract_text(line)
    Shep.Completion.parse(text)
  end

  @doc false
  def collect_port_output_for_test(port, task_id, orchestrator_pid, idle_ms) do
    collect_output(port, task_id, orchestrator_pid, idle_ms)
  end

  defp collect_output(port, task_id, orchestrator_pid, idle_ms) do
    collect_output(port, task_id, orchestrator_pid, idle_ms, [], nil)
  end

  defp collect_output(port, task_id, orchestrator_pid, idle_ms, lines, exit_code) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        send(orchestrator_pid, {:agent_output, task_id, line})
        :telemetry.execute([:shep, :agent, :stdout], %{}, %{task_id: task_id, line: line})
        collect_output(port, task_id, orchestrator_pid, idle_ms, [line | lines], exit_code)

      {^port, {:data, {:noeol, line}}} ->
        collect_output(port, task_id, orchestrator_pid, idle_ms, [line | lines], exit_code)

      {^port, {:exit_status, code}} ->
        {lines |> Enum.reverse() |> Enum.join("\n"), code}
    after
      idle_ms ->
        os_pid = Port.info(port, :os_pid)
        Port.close(port)
        kill_os_pid(os_pid)
        {lines |> Enum.reverse() |> Enum.join("\n"), 137}
    end
  end

  # Port.info/2 returns nil once the port is closed, so the pid is
  # captured before Port.close/1.
  defp kill_os_pid({:os_pid, os_pid}), do: terminate(os_pid)
  defp kill_os_pid(nil), do: :ok

  # The Port's os_pid is the agent itself: `Exec.run/6` spawns through
  # `sh -c 'exec …'`, so the shell is replaced rather than left wrapping.
  defp report_os_pid(port, task_id, orchestrator_pid) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> send(orchestrator_pid, {:agent_meta, task_id, %{os_pid: os_pid}})
      _ -> :ok
    end
  end

  @doc """
  Stop an agent's OS process: SIGTERM, then SIGKILL if it does not go.

  Killing the Elixir Task does *not* stop the agent — closing a Port
  closes pipes, it does not signal the child, and an agent spawned with
  stdin at EOF never notices. So every path that ends a task early has to
  come through here, or the agent keeps working in a worktree its
  operator was just told was theirs.

  Best effort and idempotent: a process that is already gone is fine.
  """
  @spec terminate(non_neg_integer() | nil, non_neg_integer()) :: :ok
  def terminate(os_pid, grace_ms \\ 2_000)
  def terminate(nil, _grace_ms), do: :ok

  def terminate(os_pid, grace_ms) when is_integer(os_pid) do
    pid = Integer.to_string(os_pid)
    _ = System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)

    unless await_exit(pid, grace_ms) do
      _ = System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
      _ = await_exit(pid, grace_ms)
    end

    :ok
  end

  @doc "Whether an OS process is gone. Public so callers can confirm a kill."
  @spec gone?(non_neg_integer() | nil) :: boolean()
  def gone?(nil), do: true

  def gone?(os_pid) when is_integer(os_pid) do
    match?(
      {_, code} when code != 0,
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    )
  end

  defp await_exit(_pid, remaining) when remaining <= 0, do: false

  defp await_exit(pid, remaining) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(50)
        await_exit(pid, remaining - 50)

      _ ->
        true
    end
  end
end
