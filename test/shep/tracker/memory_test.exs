defmodule Shep.Tracker.MemoryTest do
  use ExUnit.Case, async: false

  alias Shep.Tracker.Memory

  setup do
    start_supervised!({Memory, tasks: []})
    :ok
  end

  test "fetch_candidates returns empty initially" do
    assert {:ok, []} == Memory.fetch_candidates()
  end

  test "add_task and fetch" do
    task = %Shep.Task{id: "1", branch: "test/1", prompt: "hello"}
    Memory.add_task(task)
    assert {:ok, [^task]} = Memory.fetch_candidates()
  end

  test "claim sets status" do
    Memory.claim("1")
    assert "in-progress" == Memory.get_status("1")
  end

  test "update_status changes status" do
    Memory.update_status("1", "pr-created")
    assert "pr-created" == Memory.get_status("1")
  end

  test "add_comment appends" do
    Memory.add_comment("1", "first")
    Memory.add_comment("1", "second")
    assert ["first", "second"] == Memory.get_comments("1")
  end
end
