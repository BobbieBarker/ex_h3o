defmodule ExH3o.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bobbiebarker/ex_h3o"
  @force_build? System.get_env("EX_H3O_BUILD") in ["1", "true"]

  def project do
    [
      app: :ex_h3o,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # When EX_H3O_BUILD=true, compile the NIF from source via
      # elixir_make. Otherwise, RustlerPrecompiled downloads a
      # precompiled binary at compile time.
      compilers: if(@force_build?, do: [:elixir_make | Mix.compilers()], else: Mix.compilers()),
      make_targets: ["all"],
      make_clean: ["clean"],
      make_cwd: "native/ex_h3o_nif",

      # Hex
      description:
        "Elixir bindings for h3o, a Rust implementation of the H3 geospatial indexing system. " <>
          "Designed with a correct NIF boundary (C NIF + Rust staticlib), targets modern OTP 26+, " <>
          "and provides comprehensive H3 API coverage as a drop-in replacement for erlang-h3.",
      package: package(),
      source_url: @source_url,

      # Docs
      name: "ExH3o",
      docs: docs(),

      # Test
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  def application do
    [
      # :runtime_tools supplies :msacc, which the Stress.Harness uses to
      # measure dirty CPU scheduler GC pressure. Bundled with OTP, zero
      # runtime cost unless the harness is actually started.
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:rustler_precompiled, "~> 0.8"},
      {:elixir_make, "~> 0.8", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 0.6", only: [:dev, :test]},
      {:benchee, "~> 1.0", only: [:dev, :test]},
      # erlang-h3 is the reference Erlang binding for libh3 3.x, used
      # only as the comparison target for benchmarks. It vendors its
      # own libh3 C source so no system library install is required.
      {:h3, "~> 3.7", only: [:dev, :test]}
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
      maintainers: ["Bobbie Barker"],
      files: [
        "lib",
        "native/ex_h3o_nif/Cargo.toml",
        "native/ex_h3o_nif/Cargo.lock",
        "native/ex_h3o_nif/Makefile",
        "native/ex_h3o_nif/src",
        "native/ex_h3o_nif/c_src",
        "checksum-Elixir.ExH3o.Native.exs",
        "mix.exs",
        "README.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "ExH3o",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      formatters: ["html"],
      extras: [
        "README.md",
        LICENSE: [title: "License"]
      ],
      # Exclude the stress harness modules from the public hex docs:
      # they're an internal development tool, not part of the library's
      # public API. The source and moduledocs are still in the repo for
      # contributors to read.
      filter_modules: fn module, _metadata ->
        not String.starts_with?(inspect(module), "ExH3o.Stress")
      end,
      groups_for_docs: [
        "Pure Elixir": &(&1[:group] == "Pure Elixir"),
        "Cell inspection": &(&1[:group] == "Cell inspection"),
        "String conversion": &(&1[:group] == "String conversion"),
        Hierarchy: &(&1[:group] == "Hierarchy"),
        "Neighbors & distance": &(&1[:group] == "Neighbors & distance"),
        "Grid disk": &(&1[:group] == "Grid disk"),
        "Geo coordinates": &(&1[:group] == "Geo coordinates"),
        "Set operations": &(&1[:group] == "Set operations"),
        "Polygon fill": &(&1[:group] == "Polygon fill")
      ]
    ]
  end
end
