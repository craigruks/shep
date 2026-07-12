defmodule Shep.DemoTest do
  use ExUnit.Case, async: true

  alias Shep.Demo

  test "scaffold writes an executable stub agent and a valid memory-tracker workflow" do
    scaffold = Demo.scaffold()
    on_exit(fn -> File.rm_rf!(scaffold.dir) end)

    assert File.exists?(scaffold.agent)
    assert %{mode: mode} = File.stat!(scaffold.agent)
    assert Bitwise.band(mode, 0o111) != 0, "stub agent must be executable"

    content = File.read!(scaffold.workflow)
    [_, yaml, _] = String.split(content, "---", parts: 3)
    {:ok, raw} = YamlElixir.read_from_string(yaml)
    {:ok, config} = Shep.Config.Schema.validate(raw)

    assert get_in(config, ["tracker", "kind"]) == "memory"
    assert get_in(config, ["agent", "command"]) == scaffold.agent
    assert get_in(config, ["agent", "max_concurrent"]) == 1
  end

  test "cleanup removes the scaffold dir" do
    scaffold = Demo.scaffold()
    assert File.dir?(scaffold.dir)
    assert :ok = Demo.cleanup(scaffold)
    refute File.dir?(scaffold.dir)
  end
end
