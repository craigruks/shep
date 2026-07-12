defmodule Shep.Orchestrator do
  @moduledoc "Main GenServer: poll tracker, dispatch agents, monitor tasks, retry with backoff."

  use GenServer

  require Logger

  alias Shep.Orchestrator.Dispatch

  @ets_table :shep_state
  @dialyzer {:nowarn_function, init: 1}

  defstruct [
    :tick_timer,
    :tick_token,
    running: %{},
    paused: %{},
    claimed: MapSet.new(),
    retry_attempts: %{}
  ]

  @doc "Start the orchestrator."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Submit a task for execution."
  @spec submit(Shep.Task.t()) :: :ok | {:error, String.t()}
  def submit(%Shep.Task{} = task) do
    GenServer.call(__MODULE__, {:submit, task})
  end

  @doc "Pause a running task, preserving its worktree and session."
  @spec pause(String.t()) :: {:ok, map()} | {:error, String.t()}
  def pause(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:pause, task_id})
  end

  @doc "Resume a previously paused task."
  @spec resume(String.t()) :: :ok | {:error, String.t()}
  def resume(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:resume, task_id})
  end

  @doc "Kill a running task. No retry; the worktree is preserved for post-mortem."
  @spec kill(String.t()) :: :ok | {:error, String.t()}
  def kill(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:kill, task_id})
  end

  @doc "Get a snapshot of orchestrator state."
  @spec snapshot() :: map()
  def snapshot do
    case :ets.lookup(@ets_table, :state) do
      [{:state, data}] -> data
      [] -> %{running: %{}}
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@ets_table, [:named_table, :public, :set])
    state = %__MODULE__{}
    reconcile_worktrees()
    write_ets(state)
    state = schedule_tick(state)
    Logger.info("Orchestrator started")
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Orchestrator shutting down: #{inspect(reason)}")

    for {task_id, %{pid: pid}} <- state.running do
      Logger.info("Draining agent: #{task_id}")
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  @impl true
  def handle_call({:submit, task}, _from, state) do
    if Map.has_key?(state.running, task.id) || MapSet.member?(state.claimed, task.id) do
      {:reply, {:error, "task already running or claimed"}, state}
    else
      new_state = Dispatch.dispatch_task(task, state)
      write_ets(new_state)
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:kill, task_id}, _from, state) do
    case Map.get(state.running, task_id) do
      nil ->
        {:reply, {:error, "task not running"}, state}

      %{pid: pid} ->
        Process.exit(pid, :kill)
        running = Map.delete(state.running, task_id)
        state = Dispatch.clean_retry(task_id, %{state | running: running})
        write_ets(state)
        Logger.info("Killed task #{task_id} (no retry, worktree preserved)")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:pause, task_id}, _from, state) do
    case Map.get(state.running, task_id) do
      nil ->
        {:reply, {:error, "task not running"}, state}

      entry ->
        paused_task = %Shep.PausedTask{
          task: entry.task,
          worktree_path: Map.get(entry, :worktree_path, ""),
          session_name: Map.get(entry, :session_name),
          paused_at: System.monotonic_time(:millisecond)
        }

        paused = Map.put(state.paused, task_id, paused_task)
        state = %{state | paused: paused}

        Process.exit(entry.pid, :shutdown)

        Logger.info("Paused task #{task_id}")

        {:reply,
         {:ok,
          %{
            worktree_path: paused_task.worktree_path,
            session_name: paused_task.session_name
          }}, state}
    end
  end

  @impl true
  def handle_call({:resume, task_id}, _from, state) do
    case Map.get(state.paused, task_id) do
      nil ->
        {:reply, {:error, "task not paused"}, state}

      paused_task ->
        paused = Map.delete(state.paused, task_id)
        state = %{state | paused: paused}
        new_state = Dispatch.dispatch_resume(paused_task, state)
        write_ets(new_state)
        Logger.info("Resumed task #{task_id}")
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info({:tick, token}, %{tick_token: token} = state) do
    new_state = tick(state)
    new_state = schedule_tick(new_state)
    write_ets(new_state)
    {:noreply, new_state}
  end

  def handle_info({:tick, _stale_token}, state), do: {:noreply, state}

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case find_by_ref(state.running, ref) do
      {task_id, entry} ->
        new_state = Dispatch.handle_task_exit(task_id, entry, :normal, state)
        write_ets(new_state)
        {:noreply, new_state}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_by_ref(state.running, ref) do
      {task_id, entry} ->
        new_state = Dispatch.handle_task_exit(task_id, entry, reason, state)
        write_ets(new_state)
        {:noreply, new_state}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:retry_task, task_id, retry_token}, state) do
    case Map.get(state.retry_attempts, task_id) do
      %{retry_token: ^retry_token, task: task} ->
        Logger.info("Retrying task: #{task_id}")
        new_state = Dispatch.dispatch_task(task, state)
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:idle_check, task_id}, state) do
    check_idle(task_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:total_timeout, task_id}, state) do
    if Map.has_key?(state.running, task_id) do
      Logger.warning("Task #{task_id} exceeded total timeout, killing")
      kill_task(task_id, state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_meta, task_id, meta}, state) do
    case Map.get(state.running, task_id) do
      nil ->
        {:noreply, state}

      entry ->
        updated = Map.merge(entry, meta)
        {:noreply, %{state | running: Map.put(state.running, task_id, updated)}}
    end
  end

  @impl true
  def handle_info({:agent_output, task_id, _line}, state) do
    case Map.get(state.running, task_id) do
      nil ->
        {:noreply, state}

      entry ->
        updated = %{entry | last_output_at: System.monotonic_time(:millisecond)}
        {:noreply, %{state | running: Map.put(state.running, task_id, updated)}}
    end
  end

  @impl true
  def handle_info({:EXIT, port, :normal}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Orchestrator got unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp tick(state) do
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

  defp deps_resolved?(_repo, %{depends_on: nil}), do: true
  defp deps_resolved?(_repo, %{depends_on: []}), do: true

  defp deps_resolved?(repo, %{depends_on: deps}) do
    Shep.Tracker.GitHub.deps_resolved?(repo, deps)
  end

  defp check_idle(task_id, state) do
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

  defp kill_task(task_id, state) do
    case Map.get(state.running, task_id) do
      %{pid: pid} -> Process.exit(pid, :kill)
      nil -> :ok
    end
  end

  defp find_by_ref(running, ref) do
    Enum.find_value(running, fn
      {task_id, %{ref: ^ref} = entry} -> {task_id, entry}
      _ -> nil
    end)
  end

  defp schedule_tick(state) do
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

  defp write_ets(state) do
    data = %{
      running:
        Map.new(state.running, fn {id, entry} ->
          {id,
           %{
             task_type: entry.task.type,
             started_at: entry.started_at,
             last_output_at: entry.last_output_at,
             worktree_path: Map.get(entry, :worktree_path),
             session_name: Map.get(entry, :session_name)
           }}
        end),
      paused:
        Map.new(state.paused, fn {id, pt} ->
          {id,
           %{
             task_type: pt.task.type,
             worktree_path: pt.worktree_path,
             session_name: pt.session_name,
             paused_at: pt.paused_at
           }}
        end),
      claimed: MapSet.to_list(state.claimed)
    }

    :ets.insert(@ets_table, {:state, data})
  end

  defp reconcile_worktrees do
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
  end
end
