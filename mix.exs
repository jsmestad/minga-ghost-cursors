defmodule MingaGhostCursors.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jsmestad/minga-ghost-cursors"

  def project do
    [
      app: :minga_ghost_cursors,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      description: "Ghost cursor overlays for Minga agent editing sessions",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md", "LICENSE"]],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ],
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:minga_sdk, "~> 0.1.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
