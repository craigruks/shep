defmodule Shep.Env do
  @moduledoc """
  The environment Shep hands to children that run someone else's tooling.

  Shep ships as a `mix release` with a bundled ERTS, and the release
  start-up script points the process at itself two ways:

    * it exports `ROOTDIR`, `BINDIR`, `PROGNAME`, `EMU`, and `RELEASE_*`,
    * and it *prepends its own `erts-*/bin` to `PATH`*.

  `System.cmd/3` and `Port.open/2` hand that environment to children, so
  anything starting its own BEAM — `mix`, `elixir`, `iex` — resolves the
  release's `erl` and boots the release's boot script:

      cannot get bootfile '…/_build/prod/rel/shep/bin/start.boot'

  Unsetting the variables alone is not enough, because `PATH` still finds
  the release's `erl`, which derives its root right back from its own
  location. Both have to go.

  Hooks, `goal.verify`, and the agent's own shell are all such children.
  Only visible when Shep runs as a release, which is the shipped way to
  run it; from source there is no bundled ERTS and none of this is set.
  """

  @erts_vars ~w(ROOTDIR BINDIR PROGNAME EMU)

  @doc """
  Environment overrides for a child process, as `System.cmd/3` takes them.

  Unsets what the bundled runtime exported and hands back a `PATH` with
  the release's own directories removed. Empty when Shep is not running
  as a release, so a child's environment is left exactly as it was.
  """
  @spec for_child() :: [{String.t(), String.t() | nil}]
  def for_child do
    Enum.map(leaked_vars(), &{&1, nil}) ++ clean_path()
  end

  @doc "The same overrides in `Port.open/2` form: charlists, `false` to unset."
  @spec for_port() :: [{charlist(), charlist() | false}]
  def for_port do
    Enum.map(for_child(), fn
      {key, nil} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  @doc "The release root this process is running from, or nil from source."
  @spec release_root() :: String.t() | nil
  def release_root do
    System.get_env("RELEASE_ROOT") || System.get_env("ROOTDIR")
  end

  @doc """
  `PATH` with every entry inside the release root dropped.

  Public so the rule is testable on its own: the release's `erts-*/bin`
  must not be reachable by a child, or it finds the wrong `erl`.
  """
  @spec strip_release_dirs(String.t(), String.t()) :: String.t()
  def strip_release_dirs(path, root) when is_binary(path) and is_binary(root) do
    expanded_root = Path.expand(root)

    path
    |> String.split(":", trim: true)
    |> Enum.reject(&inside?(&1, expanded_root))
    |> Enum.join(":")
  end

  # On the segment boundary, so a sibling like `/rel/shep-other/bin`
  # survives while `/rel/shep/erts-16.4/bin` does not.
  defp inside?(entry, expanded_root) do
    entry = Path.expand(entry)
    entry == expanded_root or String.starts_with?(entry, expanded_root <> "/")
  end

  defp clean_path do
    with root when is_binary(root) <- release_root(),
         path when is_binary(path) <- System.get_env("PATH") do
      [{"PATH", strip_release_dirs(path, root)}]
    else
      _ -> []
    end
  end

  defp leaked_vars do
    release_vars = for {key, _} <- System.get_env(), String.starts_with?(key, "RELEASE_"), do: key

    Enum.filter(@erts_vars, &(System.get_env(&1) != nil)) ++ release_vars
  end
end
