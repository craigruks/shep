defmodule Shep.SandboxTest do
  # Only the pure surface is exercised here: naming, config resolution,
  # and the guards that fire before the CLI is ever invoked. Anything
  # that would provision a real sandbox belongs to live dogfood runs.
  use ExUnit.Case, async: true

  alias Shep.Sandbox

  defp task(id), do: %Shep.Task{id: id, branch: "b", prompt: "p", location: :vercel}

  describe "name/1" do
    test "derives a deterministic name from the task id" do
      assert Sandbox.name(task("42")) == "shep-42"
      assert Sandbox.name(task("42")) == Sandbox.name(task("42"))
    end

    test "characters a sandbox name cannot carry become hyphens" do
      assert Sandbox.name(task("feat/big thing")) == "shep-feat-big-thing"
    end

    test "distinct tasks never collide on a name" do
      refute Sandbox.name(task("5")) == Sandbox.name(task("52"))
    end
  end

  describe "remote_path/1" do
    test "defaults to the sandbox app directory" do
      assert Sandbox.remote_path(%{}) == "/vercel/sandbox/app"
    end

    test "is overridable from config" do
      assert Sandbox.remote_path(%{"sandbox" => %{"remote_path" => "/srv/app"}}) == "/srv/app"
    end
  end

  describe "provision/2" do
    test "refuses to provision without a snapshot, before touching the CLI" do
      assert {:error, reason} = Sandbox.provision(task("1"), %{})
      assert reason =~ "sandbox.snapshot is not set"
    end

    test "an empty snapshot string is treated as unset" do
      config = %{"sandbox" => %{"snapshot" => ""}}
      assert {:error, reason} = Sandbox.provision(task("1"), config)
      assert reason =~ "sandbox.snapshot is not set"
    end

    test "a token command that yields nothing fails with the command echoed" do
      config = %{
        "sandbox" => %{"snapshot" => "snap_x", "github_token_command" => "true"}
      }

      assert {:error, reason} = Sandbox.provision(task("1"), config)
      assert reason =~ "produced no token"
    end

    test "a failing token command surfaces its exit code" do
      config = %{
        "sandbox" => %{"snapshot" => "snap_x", "github_token_command" => "echo nope >&2; exit 3"}
      }

      assert {:error, reason} = Sandbox.provision(task("1"), config)
      assert reason =~ "failed (3)"
    end
  end
end
