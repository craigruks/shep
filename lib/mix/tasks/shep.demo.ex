defmodule Mix.Tasks.Shep.Demo do
  @shortdoc "Run the full orchestration loop with a stub agent. No setup needed."
  @moduledoc """
  Dispatches a demo task through the real orchestrator: memory tracker,
  isolated git worktree, streamed stub-agent output, parsed completion.
  Skips push and PR creation. Nothing leaves your machine.
  """

  use Mix.Task

  @poll_ms 300
  @timeout_ms 60_000

  @impl true
  def run(_args) do
    Application.put_env(:logger, :level, :warning)
    Application.put_env(:shep, :workflow_path, "priv/demo/WORKFLOW.md")
    Mix.Task.run("app.start")

    task = demo_task()
    {:ok, _pid} = Shep.Tracker.Memory.start_link(tasks: [task])
    attach_stream_printer()
    attach_completion_capture(self())

    IO.puts("")
    IO.puts("Shep demo: one task, the real loop, a stub agent. Nothing is pushed.")
    IO.puts("")
    IO.puts("==> Dispatching task #{task.id} into an isolated worktree...")

    :ok = Shep.Orchestrator.submit(task)
    wait_for_completion(task.id, @timeout_ms)
    cleanup_branch(task.branch)
    print_outcome(task)
  end

  defp print_outcome(task) do
    receive do
      {:agent_stop, %Shep.Completion.Complete{summary: summary}} ->
        IO.puts("""

        ==> Complete: #{summary}

        What just happened:
            1. The orchestrator claimed the task from the (in-memory) tracker
            2. It cut a git worktree on branch #{task.branch}
            3. A stub agent ran inside it; stdout streamed back line-buffered
            4. The <completion> signal was parsed and the worktree cleaned up

        With a real tracker and agent, step 4 pushes the branch, opens a PR,
        and watches CI. Point WORKFLOW.md at your repo and label an issue
        "shep" to see that version. Woof.
        """)

      {:agent_stop, completion} ->
        IO.puts("\n==> Demo did not complete cleanly: #{inspect(completion)}")
        IO.puts("    The worktree is preserved for inspection.")
    after
      0 ->
        IO.puts("\n==> Demo ended without a completion signal (crash or timeout).")
    end
  end

  defp attach_completion_capture(parent) do
    :telemetry.attach(
      "shep-demo-completion",
      [:shep, :agent, :stop],
      fn _event, _measurements, metadata, _config ->
        send(parent, {:agent_stop, metadata.completion})
      end,
      nil
    )
  end

  defp demo_task do
    n = System.unique_integer([:positive])

    %Shep.Task{
      id: "demo-#{n}",
      branch: "shep/demo-#{n}",
      base_branch: current_branch(),
      prompt: "Demonstrate the orchestration loop.",
      demo: true
    }
  end

  defp current_branch do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> "main"
    end
  end

  defp attach_stream_printer do
    :telemetry.attach(
      "shep-demo-printer",
      [:shep, :agent, :stdout],
      fn _event, _measurements, metadata, _config ->
        IO.puts("    agent | #{metadata.line}")
      end,
      nil
    )
  end

  defp wait_for_completion(task_id, remaining_ms) when remaining_ms <= 0 do
    IO.puts("Demo timed out waiting for task #{task_id}")
  end

  defp wait_for_completion(task_id, remaining_ms) do
    Process.sleep(@poll_ms)
    snapshot = Shep.Orchestrator.snapshot()

    if Map.has_key?(snapshot.running, task_id) do
      wait_for_completion(task_id, remaining_ms - @poll_ms)
    else
      :ok
    end
  end

  defp cleanup_branch(branch) do
    System.cmd("git", ["branch", "-D", branch], stderr_to_stdout: true)
  end
end
