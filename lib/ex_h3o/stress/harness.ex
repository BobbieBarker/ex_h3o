defmodule ExH3o.Stress.Harness do
  @moduledoc """
  Concurrent load generator for ex_h3o collection-returning NIFs, instrumented
  with microstate accounting (`:msacc`) to measure dirty CPU scheduler GC
  pressure.

  This module is a **development tool**, not an ExUnit test. It lives in
  `lib/` (not `test/`) so it can be invoked from `mix run bench/stress.exs`
  or from an IEx session without polluting the normal test suite.

  ## What it measures

  For a given `ExH3o.Stress.Config`, the harness:

    1. Derives a base cell from the configured coordinate + resolution.
    2. Runs a short warmup phase per worker (not measured).
    3. Captures a baseline `:erlang.statistics(:garbage_collection)` snapshot.
    4. Starts a parallel msacc sampler at the configured interval.
    5. Launches `concurrency` worker processes, each calling the target NIF
       `iterations` times with per-operation `System.monotonic_time`
       instrumentation.
    6. Stops the sampler, collects latency samples, captures the post-load
       GC snapshot.
    7. Computes throughput, latency percentiles (p50, p90, p99, p99.9, max),
       process-level GC delta, and aggregate dirty CPU scheduler gc% and
       emulator% from msacc.
    8. Returns a `ExH3o.Stress.Harness.Report` struct.

  ## Scheduler accounting caveats

  - `:msacc` has two state sets determined at BEAM compile time. On
    **default** OTP builds (`--with-microstate-accounting=yes`), the state
    set does NOT include `:nif` — NIF time is lumped into `:emulator`. The
    harness must work on default builds; it uses `gc%` as the primary
    signal and reports `emulator%` as "useful work". An extended build
    would additionally surface `:nif`, but we never require it.
  - `:msacc.start/0` and `:msacc.stop/0` are per-scheduler-thread counters.
    The sampling loop polls `:msacc.stats/0` from a helper process so the
    main flow is not blocked.
  - `:gc_fullsweep` is only present in extended mode. When aggregating we
    read it with a default of 0 so default builds Just Work.

  ## Memory caveats

  This harness measures **scheduler time** and **BEAM-side GC work**. It
  does NOT measure Rust heap allocation inside the NIF — that is invisible
  to the BEAM and would require an external tracer. See
  `docs/benchee-patterns.md` and `docs/msacc-stress-testing.md` for the
  full discussion.
  """

  alias ExH3o.Stress.Config

  @dirty_cpu :dirty_cpu_scheduler

  defmodule Report do
    @moduledoc """
    Output of a single `ExH3o.Stress.Harness.run/1` invocation.

    All latency fields are microseconds. `emulator_pct` covers both BEAM
    bytecode and NIF execution on default-mode builds. `nif_pct` is only
    populated when the BEAM was built with `--with-microstate-accounting=extra`
    and is `nil` otherwise.
    """

    @type t :: %__MODULE__{
            config: Config.t(),
            started_at: DateTime.t(),
            duration_ms: non_neg_integer(),
            total_ops: non_neg_integer(),
            ops_per_sec: float(),
            p50_us: non_neg_integer(),
            p90_us: non_neg_integer(),
            p99_us: non_neg_integer(),
            p99_9_us: non_neg_integer(),
            max_us: non_neg_integer(),
            gc_pct: float(),
            emulator_pct: float(),
            sleep_pct: float(),
            nif_pct: float() | nil,
            dirty_cpu_thread_count: non_neg_integer(),
            extended_msacc?: boolean(),
            process_gc_count_delta: integer(),
            process_gc_words_reclaimed_delta: integer(),
            system_info: map()
          }

    defstruct [
      :config,
      :started_at,
      :duration_ms,
      :total_ops,
      :ops_per_sec,
      :p50_us,
      :p90_us,
      :p99_us,
      :p99_9_us,
      :max_us,
      :gc_pct,
      :emulator_pct,
      :sleep_pct,
      :nif_pct,
      :dirty_cpu_thread_count,
      :extended_msacc?,
      :process_gc_count_delta,
      :process_gc_words_reclaimed_delta,
      :system_info
    ]
  end

  @doc """
  Runs the stress harness with the given config and returns a Report.

  This function is synchronous and can take a long time depending on
  `concurrency * iterations`. Use `ExH3o.Stress.Harness.print_report/1` to
  format the result for humans or `ExH3o.Stress.Harness.to_json/1` for
  machine-readable output.

  ## Example

      iex> config = ExH3o.Stress.Config.new(concurrency: 10, iterations: 100)
      iex> %ExH3o.Stress.Harness.Report{} = ExH3o.Stress.Harness.run(config)
  """
  @spec run(Config.t()) :: Report.t()
  def run(%Config{} = config) do
    ensure_msacc_started!()
    base_cell = derive_base_cell!(config)
    operation_fun = build_operation(config, base_cell)

    # Warmup — not measured.
    if config.warmup_iterations > 0 do
      run_workers(config.concurrency, config.warmup_iterations, operation_fun,
        record_latency: false
      )
    end

    system_info = collect_system_info(config)

    :erlang.garbage_collect()
    pre_gc = :erlang.statistics(:garbage_collection)

    :msacc.reset()
    :msacc.start()
    sampler_pid = start_msacc_sampler(config.msacc_sample_interval_ms)

    started_at = DateTime.utc_now()
    start_monotonic = System.monotonic_time(:microsecond)

    latencies =
      run_workers(config.concurrency, config.iterations, operation_fun, record_latency: true)

    duration_us = System.monotonic_time(:microsecond) - start_monotonic

    # Snap the final accumulated counters BEFORE stopping msacc. The
    # periodic sampler is an optional debugging aid — for short runs it
    # may never fire, so we always take one guaranteed final sample to
    # ensure `dirty_cpu_breakdown/1` has real data to aggregate.
    final_sample = :msacc.stats()
    :msacc.stop()
    _msacc_periodic_samples = stop_msacc_sampler(sampler_pid)
    msacc_data = final_sample

    post_gc = :erlang.statistics(:garbage_collection)
    {gc_count_pre, words_pre, _} = pre_gc
    {gc_count_post, words_post, _} = post_gc

    build_report(%{
      config: config,
      started_at: started_at,
      duration_us: duration_us,
      latencies: latencies,
      msacc_data: msacc_data,
      gc_count_delta: gc_count_post - gc_count_pre,
      gc_words_delta: words_post - words_pre,
      system_info: system_info
    })
  end

  @doc """
  Prints a human-readable report to stdout.
  """
  @spec print_report(Report.t()) :: :ok
  def print_report(%Report{} = report) do
    IO.puts(format_report(report))
  end

  @doc """
  Returns a JSON-encodable map for the report. No Jason dep — callers
  that want JSON output convert this map themselves.
  """
  @spec to_map(Report.t()) :: map()
  def to_map(%Report{} = report) do
    %{
      config: Map.from_struct(report.config),
      started_at: DateTime.to_iso8601(report.started_at),
      duration_ms: report.duration_ms,
      total_ops: report.total_ops,
      ops_per_sec: report.ops_per_sec,
      latency_us: %{
        p50: report.p50_us,
        p90: report.p90_us,
        p99: report.p99_us,
        p99_9: report.p99_9_us,
        max: report.max_us
      },
      msacc: %{
        dirty_cpu_thread_count: report.dirty_cpu_thread_count,
        extended_mode: report.extended_msacc?,
        gc_pct: report.gc_pct,
        emulator_pct: report.emulator_pct,
        sleep_pct: report.sleep_pct,
        nif_pct: report.nif_pct
      },
      process_gc: %{
        count_delta: report.process_gc_count_delta,
        words_reclaimed_delta: report.process_gc_words_reclaimed_delta
      },
      system: report.system_info
    }
  end

  # --- Operation selection ------------------------------------------------

  defp derive_base_cell!(%Config{base_coord: coord, base_resolution: res}) do
    case ExH3o.from_geo(coord, res) do
      {:ok, cell} ->
        cell

      {:error, reason} ->
        raise ArgumentError,
              "Could not derive base cell from #{inspect(coord)} at res #{res}: " <>
                inspect(reason)
    end
  end

  defp build_operation(%Config{operation: :k_ring, k_ring_k: k}, cell) do
    fn -> ExH3o.k_ring(cell, k) end
  end

  defp build_operation(%Config{operation: :k_ring_distances, k_ring_k: k}, cell) do
    fn -> ExH3o.k_ring_distances(cell, k) end
  end

  defp build_operation(
         %Config{operation: :children, children_descent: descent, base_resolution: base},
         cell
       ) do
    target_res = min(base + descent, 15)
    fn -> ExH3o.children(cell, target_res) end
  end

  defp build_operation(%Config{operation: :compact} = config, cell) do
    # Pre-compute a dense cell set that can be compacted.
    target_res = min(config.base_resolution + 1, 15)
    {:ok, dense_children} = ExH3o.children(cell, target_res)
    fn -> ExH3o.compact(dense_children) end
  end

  defp build_operation(%Config{operation: :uncompact, base_resolution: base}, cell) do
    target_res = min(base + 1, 15)
    fn -> ExH3o.uncompact([cell], target_res) end
  end

  defp build_operation(
         %Config{
           operation: :polyfill,
           polyfill_vertices: vertices,
           polyfill_resolution: res
         },
         _cell
       ) do
    fn -> ExH3o.polyfill(vertices, res) end
  end

  # --- Worker fan-out -----------------------------------------------------

  defp run_workers(concurrency, iterations, operation_fun, opts) do
    record? = Keyword.get(opts, :record_latency, true)

    1..concurrency
    |> Task.async_stream(
      fn _worker_id -> run_worker_loop(iterations, operation_fun, record?) end,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.flat_map(fn {:ok, latencies} -> latencies end)
  end

  defp run_worker_loop(iterations, operation_fun, false) do
    Enum.each(1..iterations, fn _ -> operation_fun.() end)
    []
  end

  defp run_worker_loop(iterations, operation_fun, true) do
    Enum.map(1..iterations, fn _ ->
      t0 = System.monotonic_time(:microsecond)
      _ = operation_fun.()
      System.monotonic_time(:microsecond) - t0
    end)
  end

  # --- msacc sampler ------------------------------------------------------

  defp start_msacc_sampler(interval_ms) do
    parent = self()
    spawn_link(fn -> msacc_sample_loop(parent, interval_ms, []) end)
  end

  defp stop_msacc_sampler(pid) do
    send(pid, {:stop, self()})

    receive do
      {:samples, data} -> data
    after
      3_000 -> []
    end
  end

  defp msacc_sample_loop(parent, interval_ms, acc) do
    receive do
      {:stop, caller} ->
        send(caller, {:samples, Enum.reverse(acc)})
    after
      interval_ms ->
        msacc_sample_loop(parent, interval_ms, [:msacc.stats() | acc])
    end
  end

  # --- Aggregation + reporting -------------------------------------------

  defp build_report(state) do
    %{
      config: config,
      started_at: started_at,
      duration_us: duration_us,
      latencies: latencies,
      msacc_data: msacc_data,
      gc_count_delta: gc_count_delta,
      gc_words_delta: gc_words_delta,
      system_info: system_info
    } = state

    total_ops = length(latencies)

    ops_per_sec =
      if duration_us > 0 do
        total_ops * 1_000_000 / duration_us
      else
        0.0
      end

    percentiles = compute_percentiles(latencies)

    msacc_breakdown = dirty_cpu_breakdown(msacc_data)

    %Report{
      config: config,
      started_at: started_at,
      duration_ms: div(duration_us, 1000),
      total_ops: total_ops,
      ops_per_sec: Float.round(ops_per_sec, 2),
      p50_us: percentiles.p50,
      p90_us: percentiles.p90,
      p99_us: percentiles.p99,
      p99_9_us: percentiles.p99_9,
      max_us: percentiles.max,
      gc_pct: msacc_breakdown.gc_pct,
      emulator_pct: msacc_breakdown.emulator_pct,
      sleep_pct: msacc_breakdown.sleep_pct,
      nif_pct: msacc_breakdown.nif_pct,
      dirty_cpu_thread_count: msacc_breakdown.thread_count,
      extended_msacc?: msacc_breakdown.extended?,
      process_gc_count_delta: gc_count_delta,
      process_gc_words_reclaimed_delta: gc_words_delta,
      system_info: system_info
    }
  end

  defp compute_percentiles([]),
    do: %{p50: 0, p90: 0, p99: 0, p99_9: 0, max: 0}

  defp compute_percentiles(latencies) do
    sorted = Enum.sort(latencies)
    n = length(sorted)

    %{
      p50: nth(sorted, percentile_index(n, 0.50)),
      p90: nth(sorted, percentile_index(n, 0.90)),
      p99: nth(sorted, percentile_index(n, 0.99)),
      p99_9: nth(sorted, percentile_index(n, 0.999)),
      max: List.last(sorted)
    }
  end

  defp percentile_index(n, pct), do: max(0, min(n - 1, trunc(n * pct)))
  defp nth(list, idx), do: Enum.at(list, idx)

  defp dirty_cpu_breakdown(msacc_data) do
    msacc_data
    |> Enum.filter(&(&1.type == @dirty_cpu))
    |> summarize_dirty_threads()
  end

  defp summarize_dirty_threads([]) do
    %{
      gc_pct: 0.0,
      emulator_pct: 0.0,
      sleep_pct: 0.0,
      nif_pct: nil,
      thread_count: 0,
      extended?: false
    }
  end

  defp summarize_dirty_threads([first | _] = dirty_threads) do
    extended? = Map.has_key?(first.counters, :nif)
    totals = sum_thread_counters(dirty_threads)
    total_time = totals |> Map.values() |> Enum.sum() |> max(1)

    gc_time = Map.get(totals, :gc, 0) + Map.get(totals, :gc_fullsweep, 0)
    emulator_time = Map.get(totals, :emulator, 0)
    sleep_time = Map.get(totals, :sleep, 0)

    %{
      gc_pct: pct(gc_time, total_time),
      emulator_pct: pct(emulator_time, total_time),
      sleep_pct: pct(sleep_time, total_time),
      nif_pct: if(extended?, do: pct(Map.get(totals, :nif, 0), total_time), else: nil),
      thread_count: length(dirty_threads),
      extended?: extended?
    }
  end

  defp sum_thread_counters(threads) do
    Enum.reduce(threads, %{}, fn thread, acc ->
      Map.merge(acc, thread.counters, fn _k, a, b -> a + b end)
    end)
  end

  defp pct(value, total), do: Float.round(value / total * 100, 2)

  defp collect_system_info(%Config{} = _config) do
    %{
      otp_release: System.otp_release(),
      elixir_version: System.version(),
      schedulers_online: System.schedulers_online(),
      schedulers_total: System.schedulers(),
      host: :inet.gethostname() |> elem(1) |> List.to_string(),
      machine: :erlang.system_info(:system_architecture) |> List.to_string()
    }
  end

  defp ensure_msacc_started! do
    case Application.ensure_all_started(:runtime_tools) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Could not start :runtime_tools for msacc: #{inspect(reason)}"
    end
  end

  # --- Text formatter -----------------------------------------------------

  @doc false
  def format_report(%Report{} = report) do
    config = report.config

    nif_line =
      if report.extended_msacc? do
        "  nif%:            #{report.nif_pct}%\n"
      else
        "  nif%:            not available (default msacc build)\n"
      end

    verdict = gc_verdict(report.gc_pct)

    """

    ============================================================
     ex_h3o stress harness — #{config.operation}
    ============================================================

    Configuration
    -------------
      concurrency:     #{config.concurrency}
      iterations:      #{config.iterations}
      warmup:          #{config.warmup_iterations}
      k_ring_k:        #{config.k_ring_k}
      children_descent: #{config.children_descent}
      base_coord:      #{inspect(config.base_coord)}
      base_resolution: #{config.base_resolution}
      polyfill_resolution: #{config.polyfill_resolution}

    System
    ------
      host:            #{report.system_info.host}
      machine:         #{report.system_info.machine}
      OTP:             #{report.system_info.otp_release}
      Elixir:          #{report.system_info.elixir_version}
      schedulers:      #{report.system_info.schedulers_online} / #{report.system_info.schedulers_total}
      msacc mode:      #{if report.extended_msacc?, do: "extended", else: "default"}

    Throughput
    ----------
      total ops:       #{report.total_ops}
      wall time:       #{report.duration_ms} ms
      ops/sec:         #{report.ops_per_sec}

    Latency (microseconds)
    ----------------------
      p50:             #{report.p50_us}
      p90:             #{report.p90_us}
      p99:             #{report.p99_us}
      p99.9:           #{report.p99_9_us}
      max:             #{report.max_us}

    Dirty CPU scheduler (aggregate across #{report.dirty_cpu_thread_count} threads)
    ---------------------------------------------
      gc%:             #{report.gc_pct}%
      emulator%:       #{report.emulator_pct}%
      sleep%:          #{report.sleep_pct}%
    #{nif_line}
    Process-level GC
    ----------------
      collection count delta:   #{report.process_gc_count_delta}
      words reclaimed delta:    #{report.process_gc_words_reclaimed_delta}

    Verdict
    -------
      #{verdict}
    """
  end

  defp gc_verdict(gc_pct) when gc_pct < 5.0,
    do: "gc% #{gc_pct}% — excellent, minimal GC pressure"

  defp gc_verdict(gc_pct) when gc_pct < 20.0,
    do: "gc% #{gc_pct}% — moderate, acceptable for heavy workloads"

  defp gc_verdict(gc_pct) when gc_pct < 50.0,
    do: "gc% #{gc_pct}% — HIGH, investigate term allocation patterns"

  defp gc_verdict(gc_pct),
    do: "gc% #{gc_pct}% — SEVERE, dirty schedulers spending more time in GC than useful work"
end
