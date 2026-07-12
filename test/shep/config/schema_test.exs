defmodule Shep.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Shep.Config.Schema

  describe "defaults" do
    test "goal and workspace.repo defaults are present" do
      {:ok, config} = Schema.validate(%{})
      assert get_in(config, ["goal", "verify"]) == nil
      assert get_in(config, ["goal", "verify_fixes"]) == 2
      assert get_in(config, ["goal", "ci_fixes"]) == 2
      assert get_in(config, ["workspace", "repo"]) == "."
    end

    test "agent defaults survive a partial override" do
      {:ok, config} = Schema.validate(%{"agent" => %{"max_concurrent" => 1}})
      assert get_in(config, ["agent", "max_concurrent"]) == 1
      assert get_in(config, ["agent", "command"]) == "claude"
      assert get_in(config, ["agent", "model"]) == "opus"
    end
  end

  describe "path expansion" do
    test "workspace.root expands tilde" do
      {:ok, config} = Schema.validate(%{"workspace" => %{"root" => "~/code/x"}})
      assert get_in(config, ["workspace", "root"]) == Path.join(System.user_home!(), "code/x")
    end

    test "workspace.repo expands tilde" do
      {:ok, config} = Schema.validate(%{"workspace" => %{"repo" => "~/code/x"}})
      assert get_in(config, ["workspace", "repo"]) == Path.join(System.user_home!(), "code/x")
    end
  end

  describe "validation" do
    test "rejects a non-positive max_concurrent" do
      assert {:error, reason} = Schema.validate(%{"agent" => %{"max_concurrent" => 0}})
      assert reason =~ "max_concurrent"
    end
  end
end
