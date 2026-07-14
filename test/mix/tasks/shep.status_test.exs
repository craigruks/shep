defmodule Mix.Tasks.Shep.StatusTest do
  # Pure projection over a snapshot map; no ETS or app boot.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Shep.Status

  test "project passes daemon-computed deltas through verbatim" do
    snapshot = %{
      running: %{"s1" => %{task_type: "custom", elapsed_ms: 1234, idle_ms: 42}},
      paused: %{},
      claimed: []
    }

    out = Status.project(snapshot)

    assert out.running["s1"] == %{type: "custom", elapsed_ms: 1234, idle_ms: 42}
    assert out.running_count == 1
  end

  test "project never subtracts monotonic time, so it cannot invent a negative delta" do
    # A raw per-VM stamp with no matching elapsed_ms/idle_ms: a control VM
    # subtracting `started_at` would go negative. project/1 must not.
    future_stamp = System.monotonic_time(:millisecond) + 1_000_000

    snapshot = %{
      running: %{
        "s1" => %{task_type: "custom", started_at: future_stamp, last_output_at: future_stamp}
      },
      paused: %{},
      claimed: []
    }

    entry = Status.project(snapshot).running["s1"]

    assert entry.elapsed_ms == nil
    assert entry.idle_ms == nil
  end

  test "project projects paused entries and the claimed set" do
    snapshot = %{
      running: %{},
      paused: %{
        "s2" => %{task_type: "custom", worktree_path: "/wt/s2", session_name: "shep-s2"}
      },
      claimed: ["s3"]
    }

    out = Status.project(snapshot)

    assert out.paused["s2"] == %{
             type: "custom",
             worktree_path: "/wt/s2",
             session_name: "shep-s2"
           }

    assert out.paused_count == 1
    assert out.claimed == ["s3"]
  end

  test "project tolerates a bare snapshot with missing keys" do
    assert %{running: %{}, running_count: 0, paused: %{}, paused_count: 0, claimed: []} =
             Status.project(%{})
  end
end
