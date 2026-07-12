defmodule Shep.CIWatchStub do
  @moduledoc """
  Scripted `Shep.CIWatch` adapter for tests.

  `install/2` registers the stub in the `:ci_watch_adapter` app env
  and loads a script of verdicts consumed in order, one per `watch/3`
  call; `failure_logs/2` returns a canned block. Tests that install
  the stub must be `async: false` and call `uninstall/0` in `on_exit`.
  """

  @behaviour Shep.CIWatch

  @doc "Install the stub as the CI watch adapter with scripted verdicts."
  @spec install([:passed | {:failed, String.t()}], String.t()) :: :ok
  def install(verdicts, failure_logs \\ "canned failure logs") when is_list(verdicts) do
    uninstall()

    {:ok, _pid} =
      Agent.start_link(fn -> %{verdicts: verdicts, logs: failure_logs} end, name: __MODULE__)

    Application.put_env(:shep, :ci_watch_adapter, __MODULE__)
    :ok
  end

  @doc "Remove the stub adapter and drop any remaining script."
  @spec uninstall() :: :ok
  def uninstall do
    Application.delete_env(:shep, :ci_watch_adapter)

    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> stop_agent(pid)
    end
  end

  @impl true
  def watch(_repo, _pr_number, _opts) do
    Agent.get_and_update(__MODULE__, fn %{verdicts: [verdict | rest]} = state ->
      {verdict, %{state | verdicts: rest}}
    end)
  end

  @impl true
  def failure_logs(_repo, _pr_number) do
    Agent.get(__MODULE__, & &1.logs)
  end

  defp stop_agent(pid) do
    Agent.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end
end
