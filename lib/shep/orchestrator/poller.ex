defmodule Shep.Orchestrator.Poller do
  @moduledoc """
  The orchestrator's timer-driven heartbeat: schedule the next poll,
  fetch and filter tracker candidates, watch running agents for stalls,
  and reconcile leftover worktrees at boot. Every function runs inside
  the orchestrator process, so `self()` addresses the GenServer.
  """

  require Logger

  alias Shep.Orchestrator.Dispatch

  @doc "Poll the tracker and dispatch any new, dependency-clear candidates."
  @spec tick(struct()) :: struct()
  def tick(state) do
    Logger.debug("Orchestrator tick: polling tracker")

    case Shep.Tracker.fetch_candidates() do
      {:ok, tasks} ->
        config = Shep.Config.current!()
        repo = get_in(config, ["tracker", "repo"])

        Enum.reduce(tasks, state, fn task, acc ->
          already_known =
            Map.has_key?(acc.running, task.id) ||
              MapSet.member?(acc.claimed, task.id) ||
              Map.has_key?(acc.retry_attempts, task.id)

          deps_clear = deps_resolved?(repo, task)

          if already_known || !deps_clear do
            acc
          else
            Dispatch.dispatch_task(task, acc)
          end
        end)

      {:error, reason} ->
        Logger.warning("Tracker poll failed: #{inspect(reason)}")
        state
    end
  rescue
    e ->
      Logger.error("Tick error: #{Exception.message(e)}")
      state
  end

  @doc "Whether a task's declared dependencies are all resolved."
  @spec deps_resolved?(String.t() | nil, map()) :: boolean()
  def deps_resolved?(_repo, %{depends_on: nil}), do: true
  def deps_resolved?(_repo, %{depends_on: []}), do: true

  def deps_resolved?(repo, %{depends_on: deps}) do
    Shep.Tracker.GitHub.deps_resolved?(repo, deps)
  end

  @doc "Kill a task whose agent has been silent past the idle timeout."
  @spec check_idle(String.t(), struct()) :: :ok
  def check_idle(task_id, state) do
    case Map.get(state.running, task_id) do
      %{last_output_at: last} when is_integer(last) ->
        idle_ms = System.monotonic_time(:millisecond) - last
        config = Shep.Config.current!()
        idle_timeout = get_in(config, ["agent", "idle_timeout_ms"]) || 600_000

        if idle_ms > idle_timeout do
          Logger.warning("Task #{task_id} stalled (idle #{idle_ms}ms), killing")
          Shep.Notifier.notify_stall(task_id, idle_ms)
          kill_task(task_id, state)
        end

      _ ->
        :ok
    end
  end

  @doc "Send a running task's agent process a kill signal, if it is still running."
  @spec kill_task(String.t(), struct()) :: :ok
  def kill_task(task_id, state) do
    case Map.get(state.running, task_id) do
      %{pid: pid} -> Process.exit(pid, :kill)
      nil -> :ok
    end

    :ok
  end

  @doc "Schedule the next tick, cancelling any pending one, and stamp a fresh token."
  @spec schedule_tick(struct()) :: struct()
  def schedule_tick(state) do
    if state.tick_timer, do: Process.cancel_timer(state.tick_timer)
    token = make_ref()

    config =
      try do
        Shep.Config.current!()
      rescue
        _ -> %{}
      end

    interval = get_in(config, ["polling", "interval_ms"]) || 30_000
    timer = Process.send_after(self(), {:tick, token}, interval)
    %{state | tick_timer: timer, tick_token: token}
  end

  @doc "Prune leftover git worktrees at boot so stale state does not accumulate."
  @spec reconcile_worktrees() :: :ok
  def reconcile_worktrees do
    config =
      try do
        Shep.Config.current!()
      rescue
        _ -> nil
      end

    if config do
      root = get_in(config, ["workspace", "root"])

      repo = get_in(config, ["workspace", "repo"]) || "."

      if root && File.dir?(root) do
        Shep.Worktree.prune(repo)
        Logger.info("Reconciled worktrees in #{root}")
      end
    end

    :ok
  end
end
