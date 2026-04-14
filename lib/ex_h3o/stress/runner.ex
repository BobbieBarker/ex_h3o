defmodule ExH3o.Stress.Runner do
  @moduledoc """
  CLI entry point for the stress harness. Handles environment verification,
  argv normalization, option parsing, config construction, harness invocation,
  and optional JSON report writing.

  `bench/stress.exs` is a one-line invocation of `main/1`. All of the logic
  lives here so it can be unit-tested, extended, and reviewed as normal
  module code rather than as a flat imperative script body.

  ## Design

  Every helper returns `:ok`, `{:ok, value}`, or `{:error, reason}`. The
  `main/1` function threads them through a `with` chain; the terminal
  result is handled by `handle_result/1` which either returns `:ok` or
  halts the VM with a nonzero exit code and a human-readable diagnostic.
  No `else` clauses; failures propagate via fall-through.
  """

  alias ExH3o.Stress.{Config, Harness}

  @option_spec [
    library: :string,
    operation: :string,
    concurrency: :integer,
    iterations: :integer,
    warmup: :integer,
    k: :integer,
    resolution: :integer,
    children_descent: :integer,
    polyfill_resolution: :integer,
    duration: :integer,
    json: :string
  ]

  @type error_reason ::
          {:missing_release_dylib, String.t()}
          | {:invalid_options, [{String.t(), String.t() | nil}]}
          | {:unknown_operation, String.t()}
          | {:unknown_library, String.t()}

  @doc """
  CLI entry point. Accepts `System.argv/0` and either returns `:ok` on a
  successful stress run or halts the VM with a diagnostic on failure.

  Intended call site:

      ExH3o.Stress.Runner.main(System.argv())
  """
  @spec main([String.t()]) :: :ok | no_return()
  def main(raw_argv) do
    raw_argv
    |> run()
    |> handle_result()
  end

  @spec run([String.t()]) :: :ok | {:error, error_reason()}
  defp run(raw_argv) do
    with :ok <- verify_release_dylib(),
         {:ok, opts} <- parse_options(raw_argv),
         {:ok, config} <- build_config_from_opts(opts),
         :ok <- announce(config) do
      report = Harness.run(config)
      report_to_console(report)
      maybe_write_json(report, config)
    end
  end

  # --- verification --------------------------------------------------------

  @spec verify_release_dylib() :: :ok | {:error, {:missing_release_dylib, String.t()}}
  defp verify_release_dylib do
    path = release_dylib_path()

    if File.exists?(path) do
      :ok
    else
      {:error, {:missing_release_dylib, path}}
    end
  end

  # The NIF lives at priv/ex_h3o_nif.so (built by
  # native/ex_h3o_nif/Makefile via elixir_make).
  defp release_dylib_path do
    Path.join([File.cwd!(), "priv/ex_h3o_nif.so"])
  end

  # --- option parsing ------------------------------------------------------

  # Normalizes the raw argv (stripping the optional `--` POSIX end-of-
  # options separator so both `mix run stress.exs --operation polyfill`
  # and `mix run stress.exs -- --operation polyfill` work) and parses
  # the result against `@option_spec`. Composing the normalization and
  # the parse into one helper lets the caller's `with` chain consume a
  # single `{:ok, opts} | {:error, _}` result via `<-`, instead of
  # smuggling a plain `=` binding into the chain for the normalized
  # argv.
  @spec parse_options([String.t()]) ::
          {:ok, keyword()} | {:error, {:invalid_options, [{String.t(), String.t() | nil}]}}
  defp parse_options(raw_argv) do
    case raw_argv |> normalize_argv() |> OptionParser.parse(strict: @option_spec) do
      {opts, _rest, []} -> {:ok, opts}
      {_opts, _rest, invalid} -> {:error, {:invalid_options, invalid}}
    end
  end

  defp normalize_argv(["--" | rest]), do: rest
  defp normalize_argv(argv), do: argv

  # --- library parsing (function clauses, not a case) --------------------

  @spec parse_library(keyword()) ::
          {:ok, Config.library()} | {:error, {:unknown_library, String.t()}}
  defp parse_library(opts) do
    opts
    |> Keyword.get(:library, "ex_h3o")
    |> do_parse_library()
  end

  defp do_parse_library("ex_h3o"), do: {:ok, :ex_h3o}
  defp do_parse_library("erlang_h3"), do: {:ok, :erlang_h3}
  defp do_parse_library("erlang-h3"), do: {:ok, :erlang_h3}
  defp do_parse_library("h3"), do: {:ok, :erlang_h3}
  defp do_parse_library(other), do: {:error, {:unknown_library, other}}

  # --- operation parsing (function clauses, not a case) -------------------

  @spec parse_operation(keyword()) ::
          {:ok, Config.operation()} | {:error, {:unknown_operation, String.t()}}
  defp parse_operation(opts) do
    opts
    |> Keyword.get(:operation, "polyfill")
    |> do_parse_operation()
  end

  defp do_parse_operation("k_ring"), do: {:ok, :k_ring}
  defp do_parse_operation("k_ring_distances"), do: {:ok, :k_ring_distances}
  defp do_parse_operation("children"), do: {:ok, :children}
  defp do_parse_operation("compact"), do: {:ok, :compact}
  defp do_parse_operation("uncompact"), do: {:ok, :uncompact}
  defp do_parse_operation("polyfill"), do: {:ok, :polyfill}
  defp do_parse_operation("round_trip"), do: {:ok, :round_trip}
  defp do_parse_operation("mixed_chain"), do: {:ok, :mixed_chain}
  defp do_parse_operation("null_nif"), do: {:ok, :null_nif}
  defp do_parse_operation("null_nif_dirty"), do: {:ok, :null_nif_dirty}
  defp do_parse_operation("is_valid"), do: {:ok, :is_valid}
  defp do_parse_operation("from_geo"), do: {:ok, :from_geo}
  defp do_parse_operation("to_geo"), do: {:ok, :to_geo}
  defp do_parse_operation("get_resolution"), do: {:ok, :get_resolution}
  defp do_parse_operation(other), do: {:error, {:unknown_operation, other}}

  # --- config construction ------------------------------------------------

  # Composes library parsing, operation parsing, and config construction
  # into one fallible step so the caller's `with` chain can bind the
  # config via a single `<-` instead of threading `library` and
  # `operation` through plain `=` bindings. The actual `build_config/3`
  # helper below remains infallible and scalar-arg, so the compose is
  # isolated here at the boundary where the `with` chain needs an
  # `{:ok, _} | {:error, _}` shape.
  @spec build_config_from_opts(keyword()) ::
          {:ok, Config.t()}
          | {:error, {:unknown_library, String.t()} | {:unknown_operation, String.t()}}
  defp build_config_from_opts(opts) do
    with {:ok, library} <- parse_library(opts),
         {:ok, operation} <- parse_operation(opts) do
      {:ok, build_config(library, operation, opts)}
    end
  end

  @spec build_config(Config.library(), Config.operation(), keyword()) :: Config.t()
  defp build_config(library, operation, opts) do
    Config.new(
      library: library,
      operation: operation,
      concurrency: Keyword.get(opts, :concurrency, 100),
      iterations: Keyword.get(opts, :iterations, 2_000),
      warmup_iterations: Keyword.get(opts, :warmup, 200),
      k_ring_k: Keyword.get(opts, :k, 2),
      base_resolution: Keyword.get(opts, :resolution, 9),
      children_descent: Keyword.get(opts, :children_descent, 2),
      polyfill_resolution: Keyword.get(opts, :polyfill_resolution, 9),
      duration_seconds: Keyword.get(opts, :duration),
      report_json_path: Keyword.get(opts, :json)
    )
  end

  # --- output --------------------------------------------------------------

  @spec announce(Config.t()) :: :ok
  defp announce(%Config{duration_seconds: nil} = config) do
    IO.puts("""

    Starting stress harness (iteration mode)
      library:      #{config.library}
      operation:    #{config.operation}
      concurrency:  #{config.concurrency}
      iterations:   #{config.iterations} per worker
      total ops:    #{config.concurrency * config.iterations}
      warmup:       #{config.warmup_iterations} per worker
    """)
  end

  defp announce(%Config{} = config) do
    IO.puts("""

    Starting stress harness (duration mode)
      library:      #{config.library}
      operation:    #{config.operation}
      concurrency:  #{config.concurrency}
      duration:     #{config.duration_seconds} seconds
      warmup:       #{config.warmup_iterations} per worker
    """)
  end

  @spec report_to_console(Harness.Report.t()) :: :ok
  defp report_to_console(%Harness.Report{} = report) do
    Harness.print_report(report)
  end

  @spec maybe_write_json(Harness.Report.t(), Config.t()) :: :ok
  defp maybe_write_json(_report, %Config{report_json_path: nil}), do: :ok

  defp maybe_write_json(%Harness.Report{} = report, %Config{report_json_path: path}) do
    data =
      report
      |> Harness.to_map()
      |> inspect(pretty: true, limit: :infinity)

    File.write!(path, data)
    IO.puts("Report written to #{path}")
  end

  # --- terminal result handler --------------------------------------------

  @spec handle_result(:ok | {:error, error_reason()}) :: :ok | no_return()
  defp handle_result(:ok), do: :ok

  defp handle_result({:error, {:missing_release_dylib, path}}) do
    IO.puts(:stderr, """
    ERROR: release-mode NIF dylib not found at:
      #{path}

    Stress harness MUST run against release-mode NIFs. Rebuild with:
      mix compile --force
    """)

    System.halt(1)
  end

  defp handle_result({:error, {:invalid_options, invalid}}) do
    IO.puts(:stderr, "Invalid CLI options: #{inspect(invalid)}")
    System.halt(1)
  end

  defp handle_result({:error, {:unknown_operation, op}}) do
    IO.puts(:stderr, """
    Unknown operation: #{op}

    Valid operations: k_ring, k_ring_distances, children, compact, uncompact, polyfill,
                      round_trip, mixed_chain, null_nif, null_nif_dirty, is_valid,
                      from_geo, to_geo, get_resolution
    """)

    System.halt(1)
  end

  defp handle_result({:error, {:unknown_library, lib}}) do
    IO.puts(:stderr, """
    Unknown library: #{lib}

    Valid libraries: ex_h3o, erlang_h3 (also accepted: erlang-h3, h3)
    """)

    System.halt(1)
  end
end
