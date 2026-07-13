defmodule Shep.Orchestrator.Dispatch do
  @moduledoc "Dispatch and retry logic for the orchestrator."

  require Logger

  alias Shep.Orchestrator.Poller

  @base_retry_delay_ms 10_000
  @max_retry_delay_ms 300_000

  @doc "Dispatch a task if concurrency allows, otherwise log and skip."
  @spec dispatch_task(Shep.Task.t(), struct()) :: struct()
  def dispatch_task(task, state) do
    config = Shep.Config.current!()
    max_concurrent = get_in(config, ["agent", "max_concurrent"]) || 3

    if map_size(state.running) >= max_concurrent do
      Logger.info("At max concurrency (#{max_concurrent}), queueing: #{task.id}")
      state
    else
      do_dispatch(task, config, state)
    end
  end

  @doc "Handle a completed/crashed task, triggering retry if needed."
  @spec handle_task_exit(String.t(), map(), term(), struct()) :: struct()
  def handle_task_exit(task_id, entry, reason, state) do
    Poller.cancel_watchdog(entry)
    running = Map.delete(state.running, task_id)
    state = %{state | running: running}

    if Map.has_key?(state.paused, task_id) do
      Logger.info("Task #{task_id} exited while paused, preserving pause state")
      clean_retry(task_id, state)
    else
      case reason do
        :normal ->
          Logger.info("Task exited: #{task_id}")
          clean_retry(task_id, state)

        {:shutdown, _} ->
          Logger.info("Task shut down: #{task_id}")
          clean_retry(task_id, state)

        error ->
          Logger.error("Task #{task_id} crashed: #{inspect(error)}")
          maybe_retry(task_id, entry.task, state)
      end
    end
  end

  @doc "Resume a paused task into its existing worktree with --continue."
  @spec dispatch_resume(Shep.PausedTask.t(), struct()) :: struct()
  def dispatch_resume(%Shep.PausedTask{} = paused_task, state) do
    config = Shep.Config.current!()
    task = paused_task.task

    %{pid: pid, ref: ref} =
      Task.Supervisor.async_nolink(Shep.TaskSupervisor, fn ->
        Shep.AgentRunner.run(task, self(), %{
          config: config,
          resume_worktree: paused_task.worktree_path
        })
      end)

    total_timeout = get_in(config, ["agent", "total_timeout_ms"]) || 1_200_000
    Process.send_after(self(), {:total_timeout, task.id}, total_timeout)

    entry = %{
      pid: pid,
      ref: ref,
      task: task,
      worktree_path: paused_task.worktree_path,
      session_name: paused_task.session_name,
      started_at: System.monotonic_time(:millisecond),
      last_output_at: System.monotonic_time(:millisecond)
    }

    Poller.arm_watchdog(task.id, %{state | running: Map.put(state.running, task.id, entry)})
  end

  @doc "Clean up retry state for a task."
  @spec clean_retry(String.t(), struct()) :: struct()
  def clean_retry(task_id, state) do
    case Map.get(state.retry_attempts, task_id) do
      %{timer_ref: ref} -> Process.cancel_timer(ref)
      nil -> :ok
    end

    %{state | retry_attempts: Map.delete(state.retry_attempts, task_id)}
  end

  defp do_dispatch(task, config, state) do
    Logger.info("Dispatching task #{task.id} (#{task.type || "custom"}, agent: #{task.agent})")
    claimed = MapSet.put(state.claimed, task.id)
    state = %{state | claimed: claimed}

    %{pid: pid, ref: ref} =
      Task.Supervisor.async_nolink(Shep.TaskSupervisor, fn ->
        Shep.Tracker.claim(task.id)
        Shep.AgentRunner.run(task, self(), %{config: config})
      end)

    total_timeout = get_in(config, ["agent", "total_timeout_ms"]) || 1_200_000
    Process.send_after(self(), {:total_timeout, task.id}, total_timeout)

    :telemetry.execute(
      [:shep, :orchestrator, :dispatch],
      %{},
      %{task_id: task.id, task_type: task.type}
    )

    entry = %{
      pid: pid,
      ref: ref,
      task: task,
      started_at: System.monotonic_time(:millisecond),
      last_output_at: System.monotonic_time(:millisecond)
    }

    running = Map.put(state.running, task.id, entry)
    claimed = MapSet.delete(state.claimed, task.id)
    Poller.arm_watchdog(task.id, %{state | running: running, claimed: claimed})
  end

  defp maybe_retry(task_id, task, state) do
    attempt = get_retry_attempt(task_id, state) + 1

    if attempt > 3 do
      Logger.error("Task #{task_id} exhausted retries")
      clean_retry(task_id, state)
    else
      delay =
        min((@base_retry_delay_ms * :math.pow(2, attempt - 1)) |> round(), @max_retry_delay_ms)

      token = make_ref()
      timer = Process.send_after(self(), {:retry_task, task_id, token}, delay)

      retry_entry = %{
        attempt: attempt,
        timer_ref: timer,
        retry_token: token,
        task: task,
        due_at_ms: System.monotonic_time(:millisecond) + delay
      }

      Logger.info("Scheduling retry #{attempt} for #{task_id} in #{delay}ms")
      %{state | retry_attempts: Map.put(state.retry_attempts, task_id, retry_entry)}
    end
  end

  defp get_retry_attempt(task_id, state) do
    case Map.get(state.retry_attempts, task_id) do
      %{attempt: n} -> n
      nil -> 0
    end
  end
end
