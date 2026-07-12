defmodule Shep.Tracker.GitHubTest do
  use ExUnit.Case, async: true

  alias Shep.Tracker.GitHub

  describe "parse_task_type/1" do
    test "extracts type from type: label" do
      labels = [%{"name" => "shep"}, %{"name" => "type:lint-fix"}]
      assert "lint-fix" == GitHub.parse_task_type(labels)
    end

    test "returns nil when no type label" do
      labels = [%{"name" => "shep"}, %{"name" => "bug"}]
      assert nil == GitHub.parse_task_type(labels)
    end

    test "handles empty labels" do
      assert nil == GitHub.parse_task_type([])
    end

    test "extracts custom type" do
      labels = [%{"name" => "type:custom"}]
      assert "custom" == GitHub.parse_task_type(labels)
    end
  end

  describe "no_merge?/1" do
    test "true when shep:no-merge label present" do
      labels = [
        %{"name" => "shep"},
        %{"name" => "shep:no-merge"},
        %{"name" => "type:lint-fix"}
      ]

      assert GitHub.no_merge?(labels)
    end

    test "false when no-merge label absent" do
      labels = [%{"name" => "shep"}, %{"name" => "type:lint-fix"}]
      refute GitHub.no_merge?(labels)
    end

    test "false for empty labels" do
      refute GitHub.no_merge?([])
    end
  end

  describe "parse_depends_on/1" do
    test "parses single dependency" do
      body = "Fix the bug\n\nDepends on: #42"
      assert ["42"] == GitHub.parse_depends_on(body)
    end

    test "parses multiple dependencies" do
      body = "Depends on: #12, #45, #100"
      assert ["12", "45", "100"] == GitHub.parse_depends_on(body)
    end

    test "returns empty for nil body" do
      assert [] == GitHub.parse_depends_on(nil)
    end

    test "returns empty when no depends line" do
      assert [] == GitHub.parse_depends_on("Just a regular issue body")
    end

    test "case insensitive" do
      body = "depends on: #7"
      assert ["7"] == GitHub.parse_depends_on(body)
    end

    test "handles extra whitespace" do
      body = "Depends on:   #3,  #5"
      assert ["3", "5"] == GitHub.parse_depends_on(body)
    end
  end
end

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
