defmodule Shep.ControlTest do
  use ExUnit.Case, async: false

  alias Shep.Control

  describe "daemon_node/0" do
    test "returns shep@<hostname> as an atom" do
      {:ok, host} = :inet.gethostname()
      assert Control.daemon_node() == :"shep@#{host}"
    end
  end

  describe "call/3" do
    test "answers from the daemon when reachable, else the local node" do
      assert {source, snapshot} = Control.call(Shep.Orchestrator, :snapshot, [])
      assert source in [:daemon, :local]
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :running)
    end
  end
end
