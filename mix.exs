defmodule ExH3o.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      # Phase 2 adds three Linux cross-compile targets. musl uses
      # cc_precompiler's 4-tuple form to point at `zig cc`; glibc
      # aarch64 uses Ubuntu's standard `gcc-aarch64-linux-gnu` apt
      # package via cc_precompiler's default `"aarch64-linux-gnu-"`
      # prefix (see deps/cc_precompiler/lib/cc_precompiler.ex:28-55
      # default_compilers map).
      #
      # Why not override aarch64-linux-gnu with zig cc for a uniform
      # toolchain? cc_precompiler has a bug in its
      # compilers_current_os_with_override function
      # (lib/cc_precompiler.ex:72): when include_default_ones is
      # true, Map.merge is called with a collision function that
      # returns v2 (the default value), not v1 (the user override),
      # so user overrides for keys that already exist in the default
      # map are silently dropped. Discovered during the phase 2
      # v0.1.0-rc2 dress rehearsal. Filing an upstream fix is the
      # right long-term move, but blocking on it would delay Alpine
      # Docker support, so we work around by only overriding target
      # names that don't collide with cc_precompiler's defaults
      # (both musl targets). For aarch64-linux-gnu we accept the
      # default apt prefix and install `gcc-aarch64-linux-gnu` on
      # the CI runner.
      #
      # The `{:unix, :darwin} => %{include_default_ones: true}` entry
      # is NOT decorative: without it, cc_precompiler's
      # compilers_current_os_with_override falls through to the
      # `else` branch (line 77) because the user darwin map is
      # empty and has no :include_default_ones key, so the darwin
      # jobs get a completely empty compilers map and silently
      # produce zero artifacts. Same dress-rehearsal failure mode.
      cc_precompiler: [
        only_listed_targets: true,
        compilers: %{
          {:unix, :darwin} => %{
            :include_default_ones => true
          },
          {:unix, :linux} => %{
            :include_default_ones => true,
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
