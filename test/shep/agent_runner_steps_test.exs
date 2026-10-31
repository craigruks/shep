defmodule Shep.AgentRunnerStepsTest do
  @moduledoc """
  Coverage for #99: `just shep ps` reports which step a task is in.

  Drives the real `run/3` through every step — the `on_worktree_ready`
  hook, the agent turn, a red then green verify, a red then green CI run —
  against a real git repo with a bare remote, a stub agent, a scripted CI
  verdict and a stubbed `gh`. Each step report the runner sends is folded
  through the same path the orchestrator uses (`Dispatch.record_step` →
  `Snapshot` → the `ps` projection), so the asserted `step` is the one an
  operator would read.
  """
  # Installs global adapters (:ci_watch_adapter, :tracker_adapter,
  # :gh_runner) and writes the shared :shep_state table.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Shep.Status
  alias Shep.CIWatchStub
  alias Shep.Orchestrator.{Dispatch, Snapshot}

  setup do
    start_supervised!({Shep.Tracker.Memory, tasks: []})
    Application.put_env(:shep, :tracker_adapter, Shep.Tracker.Memory)
    Application.put_env(:shep, :gh_runner, fn _args -> {:ok, "https://github.com/o/r/pull/7"} end)

    on_exit(fn ->
      Application.delete_env(:shep, :tracker_adapter)
      Application.delete_env(:shep, :gh_runner)
      CIWatchStub.uninstall()
      Snapshot.write(%Shep.Orchestrator{})
    end)

    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "shep_steps_#{n}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{n: n, dir: dir, repo: git_repo_with_remote(dir)}
  end

  # Every agent turn (first turn and each fix turn) appends a line to a
  # counter outside the worktree, so the worktree stays clean for the PR
  # and verify can go green only once a fix turn has run.
  defp config(ctx) do
    turns = Path.join(ctx.dir, "turns.txt")
    agent = Path.join(ctx.dir, "agent.sh")
    File.write!(agent, "#!/bin/sh\necho turn >> #{turns}\necho working\n")
    File.chmod!(agent, 0o755)

    %{
      "workspace" => %{"repo" => ctx.repo, "root" => Path.join(ctx.dir, "worktrees")},
      "tracker" => %{"repo" => "o/r"},
      "agent" => %{"command" => agent, "max_turns" => 1, "idle_timeout_ms" => 30_000},
      "hooks" => %{"on_worktree_ready" => "true", "hook_timeout_ms" => 5_000},
      "goal" => %{
        "verify" => "test $(wc -l < #{turns}) -ge 2",
        "verify_fixes" => 1,
        "ci_fixes" => 1
      },
      "pr" => %{"sign" => false}
    }
  end

  defp git_repo_with_remote(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    git(dir, ["init", "-q", "--bare", bare])
    git(repo, ["init", "-q", "-b", "main"])
    git(repo, ["config", "user.email", "test@example.com"])
    git(repo, ["config", "user.name", "Test"])
    git(repo, ["commit", "-q", "--allow-empty", "-m", "init"])
    git(repo, ["remote", "add", "origin", bare])
    repo
  end

  defp git(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp drain_steps(acc) do
    receive do
      {:agent_step, _id, step} -> drain_steps([step | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a task walks hook → agent → verify → ci_wait → ci_fix, and ps follows each step", ctx do
    CIWatchStub.install([{:failed, "quality"}, :passed])
    id = "st-#{ctx.n}"
    task = %Shep.Task{id: id, branch: "shep/#{id}", base_branch: "main", prompt: "p"}

    result = Shep.AgentRunner.run(task, self(), %{config: config(ctx)})
    assert %Shep.Completion.Complete{} = result.completion

    steps = drain_steps([])

    assert steps == [
             "hook",
             "agent",
             "verify",
             "verify 1/1",
             "ci_wait",
             "ci_fix 1/1",
             "ci_wait 1/1"
           ]

    claimed_at = System.monotonic_time(:millisecond) - 724_000
    entry = %{task: task, started_at: claimed_at, last_output_at: claimed_at}
    state = %Shep.Orchestrator{running: %{id => entry}}

    Enum.reduce(steps, state, fn step, state ->
      state = Dispatch.record_step(id, step, state)
      Snapshot.write(state)
      ps = Status.project(Snapshot.read()).running[id]

      assert ps.step == step
      assert ps.elapsed =~ ~r/^12m \d\ds$/
      state
    end)
  end

  test "a resumed task skips the hook and reports the agent step first", ctx do
    id = "sr-#{ctx.n}"
    task = %Shep.Task{id: id, branch: "shep/#{id}", base_branch: "main", prompt: "p", demo: true}
    {:ok, path} = Shep.Worktree.create(task.branch, "main", Path.join(ctx.dir, "wt"), ctx.repo)

    Shep.AgentRunner.run(task, self(), %{config: config(ctx), resume_worktree: path})

    assert drain_steps([]) == ["agent"]
  end
end
