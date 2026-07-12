defmodule Shep.Control do
  @moduledoc """
  Reaches a running Shep daemon over distributed Erlang.

  The daemon (started by `just shep up`) runs as a named node, `shep@<host>`.
  Control commands run in their own BEAM VM, so a plain GenServer call would
  only see an empty local orchestrator. `call/3` connects to the daemon node
  and executes there via `:rpc`; when no daemon is reachable it falls back to
  the local node, which preserves same-VM usage (iex sessions, tests).
  """

  require Logger

  @doc "The node name a Shep daemon registers under on this host."
  @spec daemon_node() :: node()
  def daemon_node do
    {:ok, host} = :inet.gethostname()
    :"shep@#{host}"
  end

  @doc """
  Run `apply(mod, fun, args)` on the daemon node if one is reachable,
  otherwise on the local node. Returns `{:daemon | :local, result}` so
  callers can tell the user which node answered.

  CLI-side only (mix tasks): the local application is started lazily,
  and only when no daemon is found, so control commands never boot a
  second polling orchestrator next to a running daemon.
  """
  @spec call(module(), atom(), [term()]) :: {:daemon | :local, term()}
  def call(mod, fun, args) do
    case connect() do
      {:ok, node} ->
        case :rpc.call(node, mod, fun, args) do
          {:badrpc, reason} ->
            Logger.warning("Daemon RPC failed (#{inspect(reason)}), running locally")
            {:local, run_local(mod, fun, args)}

          result ->
            {:daemon, result}
        end

      :error ->
        {:local, run_local(mod, fun, args)}
    end
  end

  defp run_local(mod, fun, args) do
    Mix.Task.run("app.start")
    apply(mod, fun, args)
  end

  defp connect do
    ensure_distribution()

    node = daemon_node()

    case Node.connect(node) do
      true -> {:ok, node}
      _ -> :error
    end
  end

  defp ensure_distribution do
    if Node.alive?() do
      :ok
    else
      name = :"shep_ctl_#{System.unique_integer([:positive])}"

      case Node.start(name, :shortnames) do
        {:ok, _pid} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end
end
