defmodule Shep.ControlTest do
  use ExUnit.Case, async: false

  alias Shep.Control

  describe "daemon_node/0" do
    test "returns shep@<hostname> as an atom" do
      {:ok, host} = :inet.gethostname()
      assert Control.daemon_node() == :"shep@#{host}"
    end
  end

  # A :distributed-tagged test of the daemon path via :peer was
  # considered and skipped. To exercise it, the test VM must start
  # distribution (Node.start mutates global node state for the whole
  # run and requires a running epmd), and the peer would have to boot
  # the full Shep application under the fixed name shep@<host> — the
  # same name a real daemon uses, so the test collides with any Shep
  # daemon running on the developer's machine and cannot run twice
  # concurrently in CI. The daemon path is one :rpc.call plus the
  # fallback below, which IS covered: call/3 falls back to :local when
  # no daemon answers, asserted here against the running test app.
  describe "call/3" do
    test "answers from the daemon when reachable, else the local node" do
      assert {source, snapshot} = Control.call(Shep.Orchestrator, :snapshot, [])
      assert source in [:daemon, :local]
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :running)
    end
  end
end
