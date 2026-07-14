defmodule Shep.MixProject do
  use Mix.Project

  def project do
    [
      app: :shep,
      version: "0.3.2",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Autonomous agent orchestration. You're the shepherd, Shep works the flock.",
      package: package(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix, :credo]],
      releases: releases()
    ]
  end

  # The built release IS the shipped artifact: `bin/shep` owns the daemon
  # lifecycle and the tarball bundles ERTS, so it runs with no Elixir
  # installed. Version flows from `version:` above, so `bin/shep version`
  # reports 0.3.0 with no second source of truth. Node identity + cookie
  # (so `mix shep.*` control commands :rpc into a release-run daemon) live
  # in rel/env.sh.eex.
  defp releases do
    [
      shep: [
        include_executables_for: [:unix],
        applications: [shep: :permanent]
      ]
    ]
  end

  # `dev/` holds dev-only tooling (custom credo checks) that depends on
  # :credo, which is not a prod dependency — so it must stay out of the
  # prod release compile path, otherwise `MIX_ENV=prod mix release` fails
  # to compile it.
  defp elixirc_paths(:test), do: ["lib", "test/support", "dev"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/craigruks/shep"}
    ]
  end

  def cli do
    [preferred_envs: [quality: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Shep.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict", "test"]
    ]
  end
end
