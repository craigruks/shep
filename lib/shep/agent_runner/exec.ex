defmodule Shep.AgentRunner.Exec do
  @moduledoc """
  Process execution boundary: resolve the agent executable, run it under
  a line-buffered Port, stream stdout to the orchestrator, and enforce
  the idle timeout with an explicit close + SIGKILL so no agent lingers
  as a zombie. Completion signals are parsed out of the streamed lines.
  """

  require Logger

  @max_line_length 65_536

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
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        {:line, @max_line_length},
        :stderr_to_stdout,
        {:cd, cwd},
        {:args, args}
      ])

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
  # captured before Port.close/1. SIGKILL is best-effort: the process
  # may already be gone.
  defp kill_os_pid({:os_pid, os_pid}) do
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp kill_os_pid(nil), do: :ok
end
