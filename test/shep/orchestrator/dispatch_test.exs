defmodule Shep.Orchestrator.DispatchTest do
  use ExUnit.Case, async: true

  alias Shep.Orchestrator.Dispatch

  defp task(id), do: %Shep.Task{id: id, branch: "shep/#{id}", prompt: "p"}

  defp entry(id), do: %{task: task(id), pid: self(), ref: make_ref()}

  defp crash(state, id, e) do
    state = %{state | running: Map.put(state.running, id, e)}
    Dispatch.handle_task_exit(id, e, {:badarg, []}, state)
  end

  describe "handle_task_exit/4 retry accounting" do
    test "a crash populates retry_attempts with attempt 1 and the base delay" do
      e = entry("t1")
      state = crash(%Shep.Orchestrator{}, "t1", e)

      assert %{attempt: 1, task: %Shep.Task{id: "t1"}, timer_ref: timer} =
               state.retry_attempts["t1"]

      assert state.running == %{}
      assert_in_delta Process.read_timer(timer), 10_000, 200
    end

    test "consecutive crashes increment the attempt and grow the delay" do
      e = entry("t2")
      s1 = crash(%Shep.Orchestrator{}, "t2", e)
      s2 = crash(s1, "t2", e)
      s3 = crash(s2, "t2", e)

      assert s2.retry_attempts["t2"].attempt == 2
      assert s3.retry_attempts["t2"].attempt == 3
      assert_in_delta Process.read_timer(s2.retry_attempts["t2"].timer_ref), 20_000, 200
      assert_in_delta Process.read_timer(s3.retry_attempts["t2"].timer_ref), 40_000, 200
    end

    test "the fourth crash exhausts retries and cleans the entry" do
      e = entry("t3")

      exhausted =
        %Shep.Orchestrator{}
        |> crash("t3", e)
        |> crash("t3", e)
        |> crash("t3", e)
        |> crash("t3", e)

      assert exhausted.retry_attempts == %{}
    end

    test "normal and shutdown exits clean any retry state" do
      e = entry("t4")
      crashed = crash(%Shep.Orchestrator{}, "t4", e)

      after_normal = Dispatch.handle_task_exit("t4", e, :normal, crashed)
      assert after_normal.retry_attempts == %{}

      crashed = crash(%Shep.Orchestrator{}, "t4", e)
      after_shutdown = Dispatch.handle_task_exit("t4", e, {:shutdown, :drain}, crashed)
      assert after_shutdown.retry_attempts == %{}
    end

    test "a crash while paused preserves the pause and schedules no retry" do
      e = entry("t5")

      state = %Shep.Orchestrator{
        running: %{"t5" => e},
        paused: %{"t5" => :paused_placeholder}
      }

      after_exit = Dispatch.handle_task_exit("t5", e, {:badarg, []}, state)
      assert after_exit.retry_attempts == %{}
      assert Map.has_key?(after_exit.paused, "t5")
      assert after_exit.running == %{}
    end
  end
end

defmodule Shep.Orchestrator.DispatchWiringTest do
  @moduledoc """
  Integration coverage for #25: dispatch must thread the ORCHESTRATOR pid
  (not the spawned Task's pid) into `AgentRunner.run`, so real agent stdout
  round-trips back as `{:agent_output}` and refreshes `last_output_at`.

  Before the fix the closure evaluated `self()` inside the async Task, so
  every output line was delivered to a process with no matching
  `handle_info` and the idle clock froze at dispatch. These drive the real
  `dispatch → AgentRunner → Exec → Port` path against a shell stub agent, so
  they fail on the old send target and pass on the corrected one.

  `async: false`: installs a global `Shep.Config` and the memory tracker
  adapter, both restored in `on_exit`. ExUnit never runs a sync case
  concurrently with any other test, so the global swap is safe.
  """
  use ExUnit.Case, async: false

  alias Shep.Orchestrator.Dispatch

  @stub_line "working"

  setup do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "shep_dispatch_#{n}")
    File.mkdir_p!(dir)

    orig_config = :sys.get_state(Shep.Config)
    start_supervised!({Shep.Tracker.Memory, []})
    Application.put_env(:shep, :tracker_adapter, Shep.Tracker.Memory)

    on_exit(fn ->
      Application.delete_env(:shep, :tracker_adapter)
      :sys.replace_state(Shep.Config, fn _ -> orig_config end)
      File.rm_rf!(dir)
    end)

    %{n: n, dir: dir}
  end

  test "do_dispatch threads the orchestrator pid so agent output reaches the caller",
       %{n: n, dir: dir} do
    repo = git_repo(Path.join(dir, "repo"))
    root = Path.join(dir, "worktrees")
    stub = stub_agent(dir, "0.3")

    inject_config(%{
      "workspace" => %{"repo" => repo, "root" => root},
      "agent" => %{"command" => stub, "idle_timeout_ms" => 600_000}
    })

    task = %Shep.Task{id: "do-#{n}", branch: "shep/do-#{n}", base_branch: "main", prompt: "p"}

    # The test process stands in for the orchestrator: do_dispatch captures
    # self() at entry, so a correctly-threaded pid lands output HERE.
    state = Dispatch.dispatch_task(task, %Shep.Orchestrator{})
    on_exit(fn -> Process.exit(state.running[task.id].pid, :kill) end)

    id = task.id
    assert_receive {:agent_output, ^id, line}, 5_000
    assert line =~ @stub_line
  end

  test "dispatch_resume threads the orchestrator pid so agent output reaches the caller",
       %{n: n, dir: dir} do
    wt = Path.join(dir, "resume_wt")
    File.mkdir_p!(wt)
    stub = stub_agent(dir, "0.3")

    inject_config(%{"agent" => %{"command" => stub, "idle_timeout_ms" => 600_000}})

    task = %Shep.Task{id: "res-#{n}", branch: "shep/res-#{n}", base_branch: "main", prompt: "p"}

    paused = %Shep.PausedTask{
      task: task,
      worktree_path: wt,
      session_name: "shep-#{task.id}",
      paused_at: 0
    }

    state = Dispatch.dispatch_resume(paused, %Shep.Orchestrator{})
    on_exit(fn -> Process.exit(state.running[task.id].pid, :kill) end)

    id = task.id
    assert_receive {:agent_output, ^id, line}, 5_000
    assert line =~ @stub_line
  end

  test "a task streaming past idle_timeout is not killed and last_output_at advances",
       %{n: n, dir: dir} do
    repo = git_repo(Path.join(dir, "repo"))
    root = Path.join(dir, "worktrees")
    stub = stub_agent(dir, "0.1")

    inject_config(%{
      "workspace" => %{"repo" => repo, "root" => root},
      "agent" => %{
        "command" => stub,
        "idle_timeout_ms" => 800,
        "watchdog_interval_ms" => 150,
        "heartbeat_quiet_ms" => 60_000,
        "total_timeout_ms" => 600_000
      }
    })

    task = %Shep.Task{id: "wd-#{n}", branch: "shep/wd-#{n}", base_branch: "main", prompt: "p"}
    on_exit(fn -> Shep.Orchestrator.kill(task.id) end)

    assert :ok = Shep.Orchestrator.submit(task)
    baseline = running_entry(task.id).last_output_at
    assert is_integer(baseline)

    # Stream for well over idle_timeout_ms (800). A frozen clock (the bug)
    # lets the watchdog kill at dispatch+800ms; a live clock keeps
    # refreshing on every line and the task survives.
    Process.sleep(2_000)

    entry = running_entry(task.id)

    assert entry,
           "task was killed despite continuous output (idle-kill measured wall time, not silence)"

    assert entry.last_output_at > baseline, "last_output_at never advanced past its dispatch value"

    refute is_integer(entry[:last_heartbeat_at]),
           "no liveness heartbeat should fire while the agent is actively streaming"
  end

  defp stub_agent(dir, interval) do
    path = Path.join(dir, "stub_agent.sh")

    File.write!(path, """
    #!/bin/sh
    set -eu
    while true; do
      echo #{@stub_line}
      sleep #{interval}
    done
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp git_repo(dir) do
    File.mkdir_p!(dir)
    run_git(dir, ["init", "-q", "-b", "main"])
    run_git(dir, ["config", "user.email", "test@example.com"])
    run_git(dir, ["config", "user.name", "Test"])
    File.write!(Path.join(dir, "flock.txt"), "sheep")
    run_git(dir, ["add", "."])
    run_git(dir, ["commit", "-qm", "init"])
    dir
  end

  defp run_git(dir, args) do
    {_, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
  end

  # Swap the running Shep.Config's cached config for a test one. Pointing
  # path at a nonexistent file with a nil stamp makes the 1s reload poll a
  # no-op, so the injected config survives until on_exit restores it.
  defp inject_config(overrides) do
    base = %{
      "tracker" => %{"kind" => "memory"},
      "polling" => %{"interval_ms" => 3_600_000},
      "agent" => %{"command" => "false", "max_concurrent" => 5, "max_turns" => 1},
      "hooks" => %{"on_worktree_ready" => nil}
    }

    raw = Shep.Config.Schema.deep_merge(base, overrides)
    {:ok, config} = Shep.Config.Schema.validate(raw)

    :sys.replace_state(Shep.Config, fn s ->
      %{s | config: config, path: "/nonexistent/shep_test", stamp: nil}
    end)

    config
  end

  defp running_entry(task_id) do
    :sys.get_state(Shep.Orchestrator).running[task_id]
  end
end
