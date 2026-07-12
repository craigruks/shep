defmodule Shep.RunLoggerTest do
  use ExUnit.Case

  alias Shep.RunLogger

  @runs_dir ".shep/runs"

  describe "JSONL logging" do
    test "writes event to JSONL file" do
      task_id = "logger-test-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:shep, :agent, :start],
        %{},
        %{task_id: task_id, task_type: "test"}
      )

      Process.sleep(50)

      path = Path.join(@runs_dir, "#{task_id}.jsonl")
      assert File.exists?(path)

      content = File.read!(path)
      assert String.contains?(content, task_id)
      assert String.contains?(content, "shep.agent.start")

      File.rm(path)
    end
  end

  describe "attach/detach" do
    test "attach and detach without error" do
      assert :ok = RunLogger.detach()
      assert :ok = RunLogger.attach()
    end
  end
end
