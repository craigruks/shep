defmodule Shep.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Shep.Workspace

  defp tmp_repo do
    dir = Path.join(System.tmp_dir!(), "shep_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {_, 0} = System.cmd("git", ["init", "-q", dir], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "T"])
    dir
  end

  defp sandbox_workspace do
    %Workspace{location: :vercel, path: "/vercel/sandbox/app", sandbox: "shep-42"}
  end

  describe "local workspaces" do
    test "local/1 builds a workspace whose description is just the path" do
      ws = Workspace.local("/tmp/wt")
      assert ws.location == :local
      assert ws.sandbox == nil
      assert Workspace.describe(ws) == "/tmp/wt"
    end

    test "shell/2 runs in the checkout and reports failure output" do
      ws = Workspace.local(tmp_repo())

      assert {:ok, out} = Workspace.shell(ws, "echo hello")
      assert out =~ "hello"
      assert {:error, out} = Workspace.shell(ws, "echo boom; exit 1")
      assert out =~ "boom"
    end

    test "git/2 runs against the checkout" do
      dir = tmp_repo()
      ws = Workspace.local(dir)

      assert {:ok, out} = Workspace.git(ws, ["status", "--porcelain"])
      assert String.trim(out) == ""
    end

    test "dirty?/1 tracks uncommitted changes" do
      dir = tmp_repo()
      ws = Workspace.local(dir)

      refute Workspace.dirty?(ws)
      File.write!(Path.join(dir, "new.txt"), "x")
      assert Workspace.dirty?(ws)
    end

    test "prompt_cwd/2 is the checkout itself" do
      ws = Workspace.local("/tmp/wt")
      assert Workspace.prompt_cwd(ws, %{}) == "/tmp/wt"
    end

    test "agent_spec/3 resolves the agent locally and runs in the checkout" do
      ws = Workspace.local("/tmp")

      assert {:ok, exe, ["--print"], "/tmp"} = Workspace.agent_spec(ws, "sh", ["--print"])
      assert exe =~ "sh"
    end

    test "agent_spec/3 reports the missing command by name" do
      ws = Workspace.local("/tmp")
      assert {:error, "shep-no-such-agent"} = Workspace.agent_spec(ws, "shep-no-such-agent", [])
    end

    test "reattach/3 fails cleanly when the worktree is gone" do
      task = %Shep.Task{id: "1", branch: "b", prompt: "p"}
      assert {:error, reason} = Workspace.reattach(task, "/nonexistent/path", %{})
      assert reason =~ "resume worktree not found"
    end
  end

  describe "sandbox argv" do
    test "a turn with no prompt execs the agent directly under -w" do
      argv = Workspace.remote_argv(sandbox_workspace(), "claude", ["--continue"], nil)

      assert argv == [
               "exec",
               "shep-42",
               "-w",
               "/vercel/sandbox/app",
               "--",
               "claude",
               "--continue"
             ]
    end

    # The CLI echoes every command it runs to stderr, which Shep merges
    # into the agent's own stream. A prompt on the command line would be
    # echoed back and re-parsed — including any completion sentinel the
    # issue body happens to contain.
    test "a prompt is read from a staged file, never placed on the command line" do
      argv = Workspace.remote_argv(sandbox_workspace(), "claude", ["--print"], "/tmp/p.prompt")

      refute Enum.any?(argv, &String.contains?(&1, "TASK BODY"))
      assert "/tmp/p.prompt" in argv
      assert List.last(argv) == "--print"
      assert Enum.any?(argv, &String.contains?(&1, ~S|exec "$@" -p "$(cat "$f")"|))
    end

    test "describe/1 names the sandbox and the remote path" do
      assert Workspace.describe(sandbox_workspace()) == "vercel:shep-42:/vercel/sandbox/app"
    end

    test "prompt_cwd/2 expands templates against the local repo, not the remote path" do
      config = %{"workspace" => %{"repo" => "/local/repo"}}
      assert Workspace.prompt_cwd(sandbox_workspace(), config) == "/local/repo"
    end
  end

  describe "prepare/2 guards" do
    test "codex in a sandbox is rejected rather than failing remotely" do
      task = %Shep.Task{id: "1", branch: "b", prompt: "p", agent: :codex, location: :vercel}

      assert {:error, reason} = Workspace.prepare(task, %{})
      assert reason =~ "codex is not supported in a sandbox"
    end

    test "a vercel task without a configured snapshot fails before any CLI call" do
      task = %Shep.Task{id: "1", branch: "b", prompt: "p", location: :vercel}

      assert {:error, reason} = Workspace.prepare(task, %{"sandbox" => %{"snapshot" => nil}})
      assert reason =~ "sandbox.snapshot is not set"
    end
  end

  describe "cleanup/3" do
    test "a failed local task keeps its checkout for diagnosis" do
      dir = tmp_repo()
      ws = Workspace.local(dir)

      assert :ok =
               Workspace.cleanup(ws, %Shep.Completion.Failed{reason: "x", recoverable: false}, %{})

      assert File.dir?(dir)
    end
  end
end
