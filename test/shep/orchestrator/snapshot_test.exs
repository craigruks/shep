defmodule Shep.Orchestrator.SnapshotTest do
  # Shares the process-global :shep_state table with the running
  # orchestrator, so it must not run concurrently with other cases.
  use ExUnit.Case, async: false

  alias Shep.Orchestrator.Snapshot

  # Restore an empty projection so a leftover write never leaks into
  # sibling suites that read Orchestrator.snapshot/0.
  setup do
    on_exit(fn -> Snapshot.write(%Shep.Orchestrator{}) end)
    :ok
  end

  test "read returns an empty projection shape when nothing is running" do
    Snapshot.write(%Shep.Orchestrator{})
    assert %{running: %{}, paused: %{}, claimed: []} = Snapshot.read()
  end

  test "write projects running entries down to their reportable fields" do
    task = %Shep.Task{id: "s1", type: "custom", branch: "b", prompt: "p"}

    state = %Shep.Orchestrator{
      running: %{
        "s1" => %{
          task: task,
          started_at: 111,
          last_output_at: 222,
          worktree_path: "/wt/s1",
          session_name: "shep-s1"
        }
      }
    }

    Snapshot.write(state)
    snap = Snapshot.read()

    assert %{
             task_type: "custom",
             started_at: 111,
             last_output_at: 222,
             worktree_path: "/wt/s1",
             session_name: "shep-s1"
           } = snap.running["s1"]
  end

  test "read enriches a running task with non-negative elapsed_ms/idle_ms" do
    now = System.monotonic_time(:millisecond)
    task = %Shep.Task{id: "s1", type: "custom", branch: "b", prompt: "p"}

    state = %Shep.Orchestrator{
      running: %{
        "s1" => %{task: task, started_at: now, last_output_at: now}
      }
    }

    Snapshot.write(state)
    entry = Snapshot.read().running["s1"]

    assert entry.elapsed_ms >= 0
    assert entry.idle_ms >= 0
  end

  test "read recomputes deltas each call so elapsed_ms grows with time" do
    now = System.monotonic_time(:millisecond)
    task = %Shep.Task{id: "s1", type: "custom", branch: "b", prompt: "p"}

    state = %Shep.Orchestrator{
      running: %{"s1" => %{task: task, started_at: now, last_output_at: now}}
    }

    Snapshot.write(state)
    first = Snapshot.read().running["s1"].elapsed_ms
    Process.sleep(5)
    second = Snapshot.read().running["s1"].elapsed_ms

    assert second > first
  end

  test "write projects paused entries and the claimed set" do
    task = %Shep.Task{id: "s2", type: "custom", branch: "b", prompt: "p"}

    paused = %Shep.PausedTask{
      task: task,
      worktree_path: "/wt/s2",
      session_name: "shep-s2",
      paused_at: 999
    }

    state = %Shep.Orchestrator{
      paused: %{"s2" => paused},
      claimed: MapSet.new(["s3"])
    }

    Snapshot.write(state)
    snap = Snapshot.read()

    assert %{task_type: "custom", worktree_path: "/wt/s2", session_name: "shep-s2", paused_at: 999} =
             snap.paused["s2"]

    assert snap.claimed == ["s3"]
  end
end
