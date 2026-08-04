defmodule Shep.Env do
  @moduledoc """
  The environment Shep hands to children that run someone else's tooling.

  Shep ships as a `mix release` with a bundled ERTS, and that ERTS exports
  where *it* lives: `ROOTDIR`, `BINDIR`, `PROGNAME`, `EMU`, plus the
  `RELEASE_*` set. `System.cmd/3` and `Port.open/2` pass the parent
  environment through, so any child that starts its own BEAM — `mix`,
  `elixir`, `iex` — resolves its root from those and tries to boot the
  *release's* boot script:

      cannot get bootfile '…/_build/prod/rel/shep/bin/start.boot'

  Hooks, `goal.verify`, and the agent's own shell are all such children,
  so all three unset them. Only visible when Shep runs as a release, which
  is the shipped way to run it; from source there is no bundled ERTS and
  the variables are simply absent.
  """

  @erts_vars ~w(ROOTDIR BINDIR PROGNAME EMU)

  @doc """
  Variables to unset, as `System.cmd/3` expects them.

  Only what is actually set is listed, so the child's environment is
  disturbed as little as possible.
  """
  @spec unset() :: [{String.t(), nil}]
  def unset do
    Enum.map(leaked(), &{&1, nil})
  end

  @doc "The same list in `Port.open/2` form: charlists, `false` to unset."
  @spec port_unset() :: [{charlist(), false}]
  def port_unset do
    Enum.map(leaked(), &{String.to_charlist(&1), false})
  end

  defp leaked do
    release_vars = for {key, _} <- System.get_env(), String.starts_with?(key, "RELEASE_"), do: key

    Enum.filter(@erts_vars, &(System.get_env(&1) != nil)) ++ release_vars
  end
end
