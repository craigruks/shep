defmodule Factory.Application do
  @moduledoc "OTP application supervisor — starts telemetry, config, task supervisor, orchestrator."

  use Application

  @impl true
  def start(_type, _args) do
    Factory.RunLogger.attach()

    children = [
      {Registry, keys: :unique, name: Factory.Registry},
      Factory.Config,
      {Task.Supervisor, name: Factory.TaskSupervisor},
      Factory.Orchestrator
    ]

    opts = [strategy: :one_for_one, name: Factory.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    Factory.RunLogger.detach()
    :ok
  end
end
