defmodule Factory.MixProject do
  use Mix.Project

  def project do
    [
      app: :factory,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix, :credo]]
    ]
  end

  def cli do
    [preferred_envs: [quality: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Factory.Application, []}
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
