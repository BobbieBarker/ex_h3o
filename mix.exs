defmodule ExH3o.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/bobbiebarker/ex_h3o"

  def project do
    [
      app: :ex_h3o,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # The NIF layer is a C shared object linked against a Rust
      # staticlib that wraps h3o. elixir_make drives
      # `native/ex_h3o_nif/Makefile`, which runs `cargo build` + `cc`
      # to produce `priv/ex_h3o_nif.so`.
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      make_cwd: "native/ex_h3o_nif",

      # Precompiled NIF distribution via cc_precompiler. End users
      # installing ex_h3o from hex.pm get a pre-built `.so`/`.dylib`
      # for their host triple without needing a Rust toolchain. Force
      # a local source build with `EX_H3O_BUILD=true` or by depending
      # on a `-dev` pre-release version. See plan
      # `~/.claude/plans/expressive-waddling-jellyfish.md` for the
      # full sequencing and cc_precompiler source references.
      make_precompiler: {:nif, CCPrecompiler},
      make_precompiler_url:
        "https://github.com/BobbieBarker/ex_h3o/releases/download/v#{@version}/@{artefact_filename}",
      make_precompiler_filename: "ex_h3o_nif",
      make_precompiler_nif_versions: [versions: ["2.17"]],
      make_force_build: force_build?(),
      # Phase 2 adds three Linux cross-compile targets, all driven
      # from one toolchain (zig cc via cc_precompiler's 4-tuple form,
      # plus cargo-zigbuild for the Rust side via the
      # EX_H3O_USE_ZIGBUILD=1 Makefile toggle). Overriding
      # aarch64-linux-gnu here (instead of relying on the default
      # `aarch64-linux-gnu-gcc` apt package prefix) keeps all three
      # cross jobs uniform: same zig install, same zig cc, same
      # cargo zigbuild. `include_default_ones: true` preserves the
      # macOS entries that phase 1 uses unchanged.
      #
      # See deps/cc_precompiler/lib/cc_precompiler.ex:424 for the
      # EEx render path and README.md L180-211 for the zig cc
      # 4-tuple pattern.
      cc_precompiler: [
        only_listed_targets: true,
        compilers: %{
          {:unix, :linux} => %{
            :include_default_ones => true,
            "aarch64-linux-gnu" =>
              {"zig", "zig", "<%= cc %> cc -target aarch64-linux-gnu",
               "<%= cxx %> c++ -target aarch64-linux-gnu"},
            "x86_64-linux-musl" =>
              {"zig", "zig", "<%= cc %> cc -target x86_64-linux-musl",
               "<%= cxx %> c++ -target x86_64-linux-musl"},
            "aarch64-linux-musl" =>
              {"zig", "zig", "<%= cc %> cc -target aarch64-linux-musl",
               "<%= cxx %> c++ -target aarch64-linux-musl"}
          }
        }
      ],

      # Hex
      description:
        "Elixir bindings for h3o, a Rust implementation of the H3 geospatial indexing system",
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
      {:elixir_make, "~> 0.8", runtime: false},
      {:cc_precompiler, "~> 0.1", runtime: false},
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
      # Hex tarball contents. `checksum.exs` is MANDATORY for
      # precompiled NIF verification at install time; missing it
      # breaks every `mix deps.get` with a checksum mismatch error.
      # The native/* entries enable source-build fallback when a
      # consumer sets EX_H3O_BUILD=true or uses an unsupported
      # target triple.
      files: [
        "lib",
        "native/ex_h3o_nif/c_src",
        "native/ex_h3o_nif/src",
        "native/ex_h3o_nif/Cargo.toml",
        "native/ex_h3o_nif/Cargo.lock",
        "native/ex_h3o_nif/Makefile",
        "checksum.exs",
        "mix.exs",
        "README.md",
        "LICENSE"
      ]
    ]
  end

  # Force a local source build when EX_H3O_BUILD=true is set. Also
  # triggered automatically by elixir_make whenever @version has a
  # pre-release suffix like "-dev", so working on main doesn't try
  # to download a nonexistent precompiled artifact.
  defp force_build?, do: System.get_env("EX_H3O_BUILD") in ~w(1 true TRUE)

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
