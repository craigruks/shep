defmodule Shep.Release do
  @moduledoc """
  Release health entry points for the built `bin/shep` binary.

  `mix quality` runs against source (test env, ExUnit) and structurally
  cannot catch release-only failures: a `config/runtime.exs` error, a
  missing runtime dependency, or a supervision tree that fails to boot
  only surface when the `MIX_ENV=prod` binary actually starts. `smoke/0`
  is that check — run as `bin/shep eval "Shep.Release.smoke()"`, it boots
  the full application and proves the supervision tree answers.

  The smoke is hermetic: it points config at a generated memory-tracker
  workflow (reusing the `Shep.Demo` scaffold), so no GitHub, no secrets,
  and no network are touched, and the #30 placeholder-repo guard never
  fires (the poll interval is set so no tick runs during the check).
  """

  @app :shep

  @doc """
  Boot the built system and prove its supervision tree is alive.

  Overrides `workflow_path` to a generated memory-tracker workflow,
  starts every application (so `bin/shep eval` exercises `runtime.exs`
  and the full tree), then asserts `Shep.Orchestrator.snapshot/0`
  returns a live projection — a `%{running: map}` shape that only exists
  once the orchestrator has initialised its ETS table. Prints
  `smoke: ok (shep <version>)` and returns `:ok`; any failed match
  raises, so the `bin/shep eval` process exits non-zero.
  """
  @spec smoke() :: :ok
  def smoke do
    scaffold = Shep.Demo.scaffold()

    try do
      Application.put_env(@app, :workflow_path, scaffold.workflow)
      {:ok, _started} = Application.ensure_all_started(@app)

      %{running: running} = Shep.Orchestrator.snapshot()
      true = is_map(running)

      IO.puts("smoke: ok (shep #{version()})")
      :ok
    after
      Shep.Demo.cleanup(scaffold)
    end
  end

  @doc "The running application's version string, e.g. \"0.3.1\"."
  @spec version() :: String.t()
  def version do
    @app |> Application.spec(:vsn) |> to_string()
  end
end
