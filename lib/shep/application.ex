defmodule Shep.Application do
  @moduledoc "OTP application supervisor: starts telemetry, config, task supervisor, orchestrator."

  use Application

  @impl true
  def start(_type, _args) do
    Shep.RunLogger.attach()

    children = [
      {Registry, keys: :unique, name: Shep.Registry},
      Shep.Config,
      {Task.Supervisor, name: Shep.TaskSupervisor},
      Shep.Orchestrator
    ]

    opts = [strategy: :one_for_one, name: Shep.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    Shep.RunLogger.detach()
    :ok
  end
end
