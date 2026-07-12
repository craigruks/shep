defmodule Shep.ConfigTest do
  use ExUnit.Case, async: false

  defp write_workflow(path, interval) do
    File.write!(path, """
    ---
    polling:
      interval_ms: #{interval}
    ---
    # test workflow
    """)
  end

  defp tmp_workflow do
    path =
      Path.join(System.tmp_dir!(), "shep_workflow_#{System.unique_integer([:positive])}.md")

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "loads YAML front matter and applies schema defaults" do
    path = tmp_workflow()
    write_workflow(path, 1234)
    pid = start_supervised!({Shep.Config, path: path, name: :cfg_load_test})

    assert {:ok, config} = GenServer.call(pid, :current)
    assert get_in(config, ["polling", "interval_ms"]) == 1234
    assert get_in(config, ["agent", "command"]) == "claude"
  end

  test "a missing workflow file boots with pure defaults" do
    pid = start_supervised!({Shep.Config, path: "/nonexistent/WORKFLOW.md", name: :cfg_miss_test})

    assert {:ok, config} = GenServer.call(pid, :current)
    assert get_in(config, ["polling", "interval_ms"]) == 30_000
  end

  test "hot reload picks up an edited file on the next read" do
    path = tmp_workflow()
    write_workflow(path, 1000)
    pid = start_supervised!({Shep.Config, path: path, name: :cfg_reload_test})
    assert {:ok, %{"polling" => %{"interval_ms" => 1000}}} = GenServer.call(pid, :current)

    # different byte size guarantees a new file stamp even within one second
    write_workflow(path, 424_242)
    assert {:ok, %{"polling" => %{"interval_ms" => 424_242}}} = GenServer.call(pid, :current)
  end

  test "force_reload surfaces a parse error without losing the old config" do
    path = tmp_workflow()
    write_workflow(path, 1000)
    pid = start_supervised!({Shep.Config, path: path, name: :cfg_err_test})
    assert {:ok, _} = GenServer.call(pid, :current)

    File.write!(path, "---\npolling: [broken\n---\n")
    assert {:error, _reason} = GenServer.call(pid, :force_reload)
    assert {:ok, %{"polling" => %{"interval_ms" => 1000}}} = GenServer.call(pid, :current)
  end
end
