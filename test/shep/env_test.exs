defmodule Shep.EnvTest do
  # Sets process-wide environment variables, so it must not run
  # concurrently with cases that spawn children.
  use ExUnit.Case, async: false

  alias Shep.Env

  setup do
    originals =
      for k <- ~w(ROOTDIR BINDIR PROGNAME EMU RELEASE_ROOT), into: %{}, do: {k, System.get_env(k)}

    on_exit(fn ->
      Enum.each(originals, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  defp leak_release_env do
    System.put_env("ROOTDIR", "/fake/rel/shep")
    System.put_env("BINDIR", "/fake/rel/shep/erts-16.4/bin")
    System.put_env("PROGNAME", "erl")
    System.put_env("EMU", "beam")
    System.put_env("RELEASE_ROOT", "/fake/rel/shep")
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "shep_env_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "unset/0" do
    test "lists the ERTS and RELEASE variables a bundled runtime exports" do
      leak_release_env()
      keys = Env.unset() |> Enum.map(&elem(&1, 0))

      for var <- ~w(ROOTDIR BINDIR PROGNAME EMU RELEASE_ROOT) do
        assert var in keys, "#{var} should be unset for children"
      end

      assert Enum.all?(Env.unset(), &(elem(&1, 1) == nil))
    end

    test "lists nothing that is not actually set, leaving the child alone" do
      for k <- ~w(ROOTDIR BINDIR PROGNAME EMU), do: System.delete_env(k)
      refute Enum.any?(Env.unset(), &(elem(&1, 0) in ~w(ROOTDIR BINDIR PROGNAME EMU)))
    end
  end

  # The point of the module: a child that starts its own BEAM must not
  # inherit where *this* BEAM lives, or it boots the release's boot script.
  describe "children do not inherit the release runtime" do
    test "a hook sees no ROOTDIR or BINDIR" do
      leak_release_env()
      dir = tmp_dir()
      out_file = Path.join(dir, "env.txt")

      assert :ok =
               Shep.Hooks.run(
                 "printenv ROOTDIR > #{out_file}; printenv BINDIR >> #{out_file}; true",
                 dir,
                 name: "test"
               )

      assert File.read!(out_file) == ""
    end

    test "a verify command sees no ROOTDIR or BINDIR" do
      leak_release_env()
      dir = tmp_dir()
      workspace = Shep.Workspace.local(dir)

      assert {:ok, out} = Shep.Goal.run_verify("printenv ROOTDIR; printenv BINDIR; true", workspace)
      assert String.trim(out) == ""
    end

    test "the agent's own process sees no ROOTDIR or BINDIR" do
      leak_release_env()
      dir = tmp_dir()
      script = Path.join(dir, "agent.sh")
      File.write!(script, "#!/bin/sh\nprintenv ROOTDIR\nprintenv BINDIR\necho AGENT_DONE\n")
      File.chmod!(script, 0o755)

      task = %Shep.Task{id: "env-1", branch: "b", prompt: "p"}
      result = Shep.AgentRunner.Exec.run(script, [], dir, task, self(), 5_000)

      assert result.stdout == "AGENT_DONE"
    end
  end
end
