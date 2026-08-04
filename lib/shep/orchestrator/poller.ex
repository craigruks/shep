defmodule Shep.Orchestrator.Poller do
  @moduledoc """
  The orchestrator's timer-driven heartbeat: schedule the next poll,
  fetch and filter tracker candidates, run the recurring per-task
  watchdog (idle kill + gap-triggered liveness heartbeat), and reconcile
  leftover worktrees at boot. Every function runs inside the orchestrator
  process, so `self()` addresses the GenServer.
  """

  require Logger

  alias Shep.Orchestrator.Dispatch

  @placeholder_repo "your-org/your-repo"

  @doc "Poll the tracker and dispatch any new, dependency-clear candidates."
  @spec tick(struct()) :: struct()
  def tick(state), do: tick(state, current_config())

  @doc """
  Config-injected tick. Emits one `:info` pulse per tick so the release
  daemon log shows a sign of life between milestones. When `tracker.repo`
  is blank or the template placeholder, it fails loud with a `:warning`
  and skips the fetch — a misconfiguration must announce itself (#30).
  """
  @spec tick(struct(), map()) :: struct()
  def tick(state, config) do
    repo = get_in(config, ["tracker", "repo"])

    if placeholder_repo?(repo) do
      Logger.warning(
        "tracker.repo is #{inspect(repo)} (the template default) — set tracker.repo in your " <>
          "WORKFLOW.md or pass SHEP_WORKFLOW. Not polling."
      )

      state
    else
      Logger.info("tick: watching #{repo} — #{tick_status(state)}")
      poll_and_dispatch(state, repo)
    end
  rescue
    e ->
      Logger.error("Tick error: #{Exception.message(e)}")
      state
  end

  defp poll_and_dispatch(state, repo) do
    case Shep.Tracker.fetch_candidates() do
      {:ok, tasks} ->
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
  end

  defp placeholder_repo?(nil), do: true

  defp placeholder_repo?(repo) when is_binary(repo),
    do: String.trim(repo) in ["", @placeholder_repo]

  defp placeholder_repo?(_), do: true

  defp tick_status(state) do
    running = map_size(state.running)
    claimed = MapSet.size(state.claimed)

    if running == 0 and claimed == 0 do
      "idle (0 running, 0 claimed)"
    else
      "#{running} running, #{claimed} claimed#{running_suffix(state)}"
    end
  end

  defp running_suffix(state) do
    case Map.keys(state.running) do
      [] -> ""
      ids -> " (" <> (ids |> Enum.map_join(", ", &"task #{&1} running")) <> ")"
    end
  end

  @doc "Whether a task's declared dependencies are all resolved."
  @spec deps_resolved?(String.t() | nil, map()) :: boolean()
  def deps_resolved?(_repo, %{depends_on: nil}), do: true
  def deps_resolved?(_repo, %{depends_on: []}), do: true

  def deps_resolved?(repo, %{depends_on: deps}) do
    Shep.Tracker.GitHub.deps_resolved?(repo, deps)
  end

  @default_watchdog_interval_ms 15_000
  @default_heartbeat_quiet_ms 30_000
  @default_idle_timeout_ms 600_000

  @doc """
  One recurring watchdog tick, two cadences. Fires on a token so a stray
  timer can never act on a re-dispatched task id. If the token is stale or
  the task has exited, the loop stops (no re-arm). Otherwise: kill on idle,
  else emit a gap-triggered heartbeat and re-arm.
  """
  @spec watchdog_tick(String.t(), reference(), struct()) :: struct()
  def watchdog_tick(task_id, token, state) do
    case Map.get(state.running, task_id) do
      %{watchdog_token: ^token, last_output_at: last} = entry when is_integer(last) ->
        config = current_config()
        quiet_ms = System.monotonic_time(:millisecond) - last

        if quiet_ms > idle_timeout_ms(config) do
          Logger.warning("Task #{task_id} stalled (idle #{quiet_ms}ms), killing")
          Shep.Notifier.notify_stall(task_id, quiet_ms)
          kill_task(task_id, state)
          state
        else
          entry = maybe_heartbeat(task_id, entry, quiet_ms, config)
          arm_watchdog(task_id, %{state | running: Map.put(state.running, task_id, entry)})
        end

      _ ->
        state
    end
  end

  @doc "Arm (or re-arm) the recurring watchdog for a running task with a fresh token."
  @spec arm_watchdog(String.t(), struct()) :: struct()
  def arm_watchdog(task_id, state) do
    case Map.get(state.running, task_id) do
      nil ->
        state

      entry ->
        cancel_watchdog(entry)
        token = make_ref()
        interval = watchdog_interval_ms(current_config())
        timer = Process.send_after(self(), {:watchdog, task_id, token}, interval)
        entry = Map.merge(entry, %{watchdog_timer: timer, watchdog_token: token})
        %{state | running: Map.put(state.running, task_id, entry)}
    end
  end

  @doc "Cancel a task's pending watchdog timer, if any. Safe to call repeatedly."
  @spec cancel_watchdog(map()) :: :ok
  def cancel_watchdog(%{watchdog_timer: timer}) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  def cancel_watchdog(_entry), do: :ok

  @doc "Watchdog cadence: the finer of the configured interval and the idle timeout."
  @spec watchdog_interval_ms(map()) :: pos_integer()
  def watchdog_interval_ms(config) do
    interval = get_in(config, ["agent", "watchdog_interval_ms"]) || @default_watchdog_interval_ms
    min(interval, idle_timeout_ms(config))
  end

  defp maybe_heartbeat(task_id, entry, quiet_ms, config) do
    heartbeat_quiet = get_in(config, ["agent", "heartbeat_quiet_ms"]) || @default_heartbeat_quiet_ms

    if quiet_ms >= heartbeat_quiet and heartbeat_due?(entry, heartbeat_quiet) do
      idle_min = div(idle_timeout_ms(config), 60_000)

      Logger.info(
        "task #{task_id} alive: agent quiet #{div(quiet_ms, 1000)}s (idle kill at #{idle_min}m)"
      )

      Map.put(entry, :last_heartbeat_at, System.monotonic_time(:millisecond))
    else
      entry
    end
  end

  defp heartbeat_due?(entry, heartbeat_quiet) do
    case Map.get(entry, :last_heartbeat_at) do
      nil -> true
      last -> System.monotonic_time(:millisecond) - last >= heartbeat_quiet
    end
  end

  defp idle_timeout_ms(config) do
    get_in(config, ["agent", "idle_timeout_ms"]) || @default_idle_timeout_ms
  end

  defp current_config do
    Shep.Config.current!()
  rescue
    _ -> %{}
  end

  @doc "Send a running task's agent process a kill signal, if it is still running."
  @spec kill_task(String.t(), struct()) :: :ok
  def kill_task(task_id, state) do
    case Map.get(state.running, task_id) do
      %{pid: pid, task: task} = entry ->
        Process.exit(pid, :kill)
        # Neither the Task's death nor closing its Port signals the agent,
        # so the OS process is stopped explicitly.
        Shep.AgentRunner.Exec.terminate(Map.get(entry, :os_pid))
        # The runner's own cleanup dies with the process, so a remote
        # workspace has to be released here or it bills until its timeout.
        Shep.Sandbox.release(task)

      _ ->
        :ok
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

  @doc """
  Schedule the next tidy sweep, cancelling any pending one.

  Returns the state unchanged when `workspace.tidy_interval_ms` is zero or
  absent, so the sweep is opt-out without a separate flag.
  """
  @spec schedule_tidy(struct()) :: struct()
  def schedule_tidy(state) do
    if state.tidy_timer, do: Process.cancel_timer(state.tidy_timer)

    case get_in(current_config(), ["workspace", "tidy_interval_ms"]) do
      interval when is_integer(interval) and interval > 0 ->
        token = make_ref()
        timer = Process.send_after(self(), {:tidy, token}, interval)
        %{state | tidy_timer: timer, tidy_token: token}

      _ ->
        %{state | tidy_timer: nil, tidy_token: nil}
    end
  end

  @doc """
  Run a tidy sweep off the orchestrator process.

  Reclaiming touches git and the network, so it happens in a supervised
  Task: the error kernel holds, and a slow fetch never stalls dispatch.
  """
  @spec start_tidy() :: :ok
  def start_tidy do
    Task.Supervisor.start_child(Shep.TaskSupervisor, fn ->
      report = Shep.Tidy.run()
      reaped = length(report.reaped)
      sandboxes = length(report.sandboxes)

      if reaped > 0 or sandboxes > 0 do
        Logger.info("Tidy reclaimed #{reaped} worktree(s), #{sandboxes} sandbox(es)")
      end
    end)

    :ok
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

      reconcile_sandboxes(config)
    end

    :ok
  end

  # Nothing is running at boot, so every sandbox this daemon could have
  # created is an orphan a crash left billing. Skipped entirely unless
  # sandboxes are configured, so the local-only path costs no CLI call.
  defp reconcile_sandboxes(config) do
    case get_in(config, ["sandbox", "snapshot"]) do
      snapshot when is_binary(snapshot) and snapshot != "" ->
        case Shep.Sandbox.sweep(config, []) do
          {:ok, []} -> :ok
          {:ok, names} -> Logger.info("Reaped #{length(names)} orphaned sandbox(es) at boot")
          {:error, reason} -> Logger.warning("Could not reconcile sandboxes: #{reason}")
        end

      _ ->
        :ok
    end
  end
end
