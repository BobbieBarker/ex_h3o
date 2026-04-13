defmodule ExH3o.Stress.Runner do
  @moduledoc """
  CLI entry point for the stress harness. Handles environment verification,
  argv normalization, option parsing, config construction, harness invocation,
  and optional JSON report writing.

  `bench/stress.exs` is a one-line invocation of `main/1` — all of the logic
  lives here so it can be unit-tested, extended, and reviewed as normal
  module code rather than as a flat imperative script body.

  ## Design

  Every helper returns `:ok`, `{:ok, value}`, or `{:error, reason}`. The
  `main/1` function threads them through a `with` chain; the terminal
  result is handled by `handle_result/1` which either returns `:ok` or
  halts the VM with a nonzero exit code and a human-readable diagnostic.
  No `else` clauses — failures propagate via fall-through.
  """

  alias ExH3o.Stress.{Config, Harness}

  @option_spec [
    operation: :string,
    concurrency: :integer,
    iterations: :integer,
    warmup: :integer,
    k: :integer,
    resolution: :integer,
    children_descent: :integer,
    polyfill_resolution: :integer,
    json: :string
  ]

  @type error_reason ::
          {:missing_release_dylib, String.t()}
          | {:invalid_options, [{String.t(), String.t() | nil}]}
          | {:unknown_operation, String.t()}

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
         argv = normalize_argv(raw_argv),
         {:ok, opts} <- parse_options(argv),
         {:ok, operation} <- parse_operation(opts),
         config = build_config(operation, opts),
         :ok <- announce(config),
         report = Harness.run(config),
         :ok <- report_to_console(report) do
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

  defp release_dylib_path do
    Path.join([File.cwd!(), "native/ex_h3o_nif/target/release/libex_h3o_nif.dylib"])
  end

  # --- argv normalization --------------------------------------------------
  #
  # `mix run script.exs -- --flag value` passes `["--", "--flag", "value"]`
  # because `--` is the POSIX end-of-options separator. OptionParser stops
  # at `--`. Drop it so both `mix run stress.exs --operation polyfill` and
  # `mix run stress.exs -- --operation polyfill` work.

  defp normalize_argv(["--" | rest]), do: rest
  defp normalize_argv(argv), do: argv

  # --- option parsing ------------------------------------------------------

  @spec parse_options([String.t()]) ::
          {:ok, keyword()} | {:error, {:invalid_options, [{String.t(), String.t() | nil}]}}
  defp parse_options(argv) do
    case OptionParser.parse(argv, strict: @option_spec) do
      {opts, _rest, []} -> {:ok, opts}
      {_opts, _rest, invalid} -> {:error, {:invalid_options, invalid}}
    end
  end

  # --- operation parsing (function clauses, not a case) -------------------

  @spec parse_operation(keyword()) ::
          {:ok, Config.operation()} | {:error, {:unknown_operation, String.t()}}
  defp parse_operation(opts) do
    opts
    |> Keyword.get(:operation, "k_ring")
    |> do_parse_operation()
  end

  defp do_parse_operation("k_ring"), do: {:ok, :k_ring}
  defp do_parse_operation("k_ring_distances"), do: {:ok, :k_ring_distances}
  defp do_parse_operation("children"), do: {:ok, :children}
  defp do_parse_operation("compact"), do: {:ok, :compact}
  defp do_parse_operation("uncompact"), do: {:ok, :uncompact}
  defp do_parse_operation("polyfill"), do: {:ok, :polyfill}
  defp do_parse_operation(other), do: {:error, {:unknown_operation, other}}

  # --- config construction ------------------------------------------------

  @spec build_config(Config.operation(), keyword()) :: Config.t()
  defp build_config(operation, opts) do
    Config.new(
      operation: operation,
      concurrency: Keyword.get(opts, :concurrency, 100),
      iterations: Keyword.get(opts, :iterations, 2_000),
      warmup_iterations: Keyword.get(opts, :warmup, 200),
      k_ring_k: Keyword.get(opts, :k, 2),
      base_resolution: Keyword.get(opts, :resolution, 9),
      children_descent: Keyword.get(opts, :children_descent, 2),
      polyfill_resolution: Keyword.get(opts, :polyfill_resolution, 9),
      report_json_path: Keyword.get(opts, :json)
    )
  end

  # --- output --------------------------------------------------------------

  @spec announce(Config.t()) :: :ok
  defp announce(%Config{} = config) do
    IO.puts("""

    Starting ex_h3o stress harness
      operation:    #{config.operation}
      concurrency:  #{config.concurrency}
      iterations:   #{config.iterations} per worker
      total ops:    #{config.concurrency * config.iterations}
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

    Valid operations: k_ring, k_ring_distances, children, compact, uncompact, polyfill
    """)

    System.halt(1)
  end
end
