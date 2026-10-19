defmodule Tailscaled.MixProject do
  use Mix.Project

  @source_url "https://github.com/sid2baker/tailscaled_ex"

  def project do
    [
      app: :tailscaled_ex,
      version: "0.4.0",
      name: "Tailscaled",
      description: "Supervised tailscaled integration for Elixir and Nerves via LocalAPI",
      source_url: @source_url,
      package: package(),
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md"]],
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      aliases: aliases(),
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")]
    ]
  end

  def application do
    [
      mod: {Tailscaled.Application, []},
      extra_applications: [:crypto, :inets, :logger, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs .formatter.exs README.md CHANGELOG.md CONTRIBUTING.md LICENSE)
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:mint, "~> 1.11"},
      {:property_table, "~> 0.3.4"},
      {:muontrap, "~> 1.0"}
    ]
  end

  defp aliases() do
    [
      test: ["test --no-start"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
