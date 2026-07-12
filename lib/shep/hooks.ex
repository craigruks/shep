defmodule Shep.Hooks do
  @moduledoc "Lifecycle hook execution with configurable timeout."

  require Logger

  @doc "Run a named hook in the given working directory."
  @spec run(String.t() | nil, String.t(), keyword()) :: :ok | {:error, String.t()}
  def run(command, cwd, opts \\ [])
  def run(nil, _cwd, _opts), do: :ok

  def run(command, cwd, opts) when is_binary(command) and is_binary(cwd) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    hook_name = Keyword.get(opts, :name, "hook")

    :telemetry.execute(
      [:shep, :hook, :start],
      %{},
      %{hook: hook_name, command: command}
    )

    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", command], cd: cwd, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {_output, 0}} ->
        :telemetry.execute([:shep, :hook, :stop], %{}, %{hook: hook_name, exit_code: 0})
        :ok

      {:ok, {output, code}} ->
        Logger.warning("Hook #{hook_name} exited #{code}: #{String.trim(output)}")
        :telemetry.execute([:shep, :hook, :stop], %{}, %{hook: hook_name, exit_code: code})
        {:error, "hook exited #{code}"}

      nil ->
        Logger.warning("Hook #{hook_name} timed out after #{timeout}ms")
        :telemetry.execute([:shep, :hook, :stop], %{}, %{hook: hook_name, exit_code: :timeout})
        {:error, "hook timed out"}
    end
  end

  @doc "Run all configured hooks for a lifecycle event."
  @spec run_lifecycle(map(), String.t(), String.t()) :: :ok
  def run_lifecycle(config, event, cwd) when is_binary(event) and is_binary(cwd) do
    command = get_in(config, ["hooks", event])
    timeout = get_in(config, ["hooks", "hook_timeout_ms"]) || 120_000
    run(command, cwd, timeout: timeout, name: event)
    :ok
  end
end
