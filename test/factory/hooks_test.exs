defmodule Factory.HooksTest do
  use ExUnit.Case, async: true

  alias Factory.Hooks

  describe "run/3" do
    test "returns :ok for nil command" do
      assert :ok = Hooks.run(nil, System.tmp_dir!())
    end

    test "runs a successful command" do
      assert :ok = Hooks.run("true", System.tmp_dir!(), name: "test")
    end

    test "returns error for failed command" do
      assert {:error, _} = Hooks.run("exit 1", System.tmp_dir!(), name: "test")
    end

    test "returns error on timeout" do
      assert {:error, "hook timed out"} =
               Hooks.run("sleep 10", System.tmp_dir!(), timeout: 100, name: "test")
    end
  end

  describe "run_lifecycle/3" do
    test "runs hook from config" do
      config = %{"hooks" => %{"on_worktree_ready" => "true", "hook_timeout_ms" => 5000}}
      assert :ok = Hooks.run_lifecycle(config, "on_worktree_ready", System.tmp_dir!())
    end

    test "skips nil hook" do
      config = %{"hooks" => %{"on_worktree_ready" => nil}}
      assert :ok = Hooks.run_lifecycle(config, "on_worktree_ready", System.tmp_dir!())
    end
  end
end
