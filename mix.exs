defmodule ExH3o.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bobbiebarker/ex_h3o"

  def project do
    [
      app: :ex_h3o,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # Hex
      description:
        "Elixir bindings for h3o — a Rust implementation of the H3 geospatial indexing system",
      package: package(),
      source_url: @source_url,

      # Docs
      name: "ExH3o",
      docs: docs(),

      # Test
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/project.plt"},
      plt_add_apps: [:mix]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Bobbie Barker"]
    ]
  end

  defp docs do
    [
      main: "ExH3o",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
