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
    set does NOT include `:nif`. NIF time is lumped into `:emulator`. The
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
  does NOT measure Rust heap allocation inside the NIF; that is invisible
  to the BEAM and would require an external tracer.
  """

  alias ExH3o.Stress.Config

  @dirty_cpu :dirty_cpu_scheduler
  @normal :scheduler

  # Major-city coordinates used as seed points for the :mixed_chain
  # operation. The harness derives one cell per coordinate at load time
  # and rotates workers through them per iteration so the measurement
  # isn't dominated by CPU cache effects on a single cell.
  @mixed_chain_seed_coords [
    {37.7749, -122.4194},
    {40.7128, -74.0060},
    {51.5074, -0.1278},
    {48.8566, 2.3522},
    {35.6762, 139.6503},
    {-33.8688, 151.2093},
    {-22.9068, -43.1729},
    {55.7558, 37.6173}
  ]

  defmodule Report do
    @moduledoc """
    Output of a single `ExH3o.Stress.Harness.run/1` invocation.

    All latency fields are microseconds. `emulator_pct` covers both BEAM
    bytecode and NIF execution on default-mode builds. `nif_pct` is only
    populated when the BEAM was built with `--with-microstate-accounting=extra`
    and is `nil` otherwise.
    """

    @type scheduler_breakdown :: %{
            gc_pct: float(),
            emulator_pct: float(),
            sleep_pct: float(),
            nif_pct: float() | nil,
            thread_count: non_neg_integer()
          }

    @type per_worker_gc :: %{
            workers: non_neg_integer(),
            gc_count_total: non_neg_integer(),
            gc_count_avg: float(),
            gc_count_max: non_neg_integer(),
            heap_growth_words_total: integer(),
            heap_growth_words_avg: float(),
            heap_growth_words_max: integer(),
            memory_growth_bytes_total: integer(),
            memory_growth_bytes_avg: float(),
            memory_growth_bytes_max: integer()
          }

    @type t :: %__MODULE__{
            config: Config.t(),
            started_at: DateTime.t(),
            duration_ms: non_neg_integer(),
            total_ops: non_neg_integer(),
            ops_per_sec: float(),
            ns_per_op: float(),
            p50_us: non_neg_integer(),
            p90_us: non_neg_integer(),
            p99_us: non_neg_integer(),
            p99_9_us: non_neg_integer(),
            max_us: non_neg_integer(),
            dirty_cpu: scheduler_breakdown(),
            normal: scheduler_breakdown(),
            extended_msacc?: boolean(),
            process_gc_count_delta: integer(),
            process_gc_words_reclaimed_delta: integer(),
            absolute_gc_ns_per_op: float(),
            absolute_dirty_gc_ns_per_op: float(),
            per_worker_gc: per_worker_gc() | nil,
            system_info: map()
          }

    defstruct [
      :config,
      :started_at,
      :duration_ms,
      :total_ops,
      :ops_per_sec,
      :ns_per_op,
      :p50_us,
      :p90_us,
      :p99_us,
      :p99_9_us,
      :max_us,
      :dirty_cpu,
      :normal,
      :extended_msacc?,
      :process_gc_count_delta,
      :process_gc_words_reclaimed_delta,
      :absolute_gc_ns_per_op,
      :absolute_dirty_gc_ns_per_op,
      :per_worker_gc,
      :system_info
    ]
  end

  @doc """
  Runs the stress harness with the given config and returns a Report.

  This function is synchronous and can take a long time depending on
  `concurrency * iterations`. Use `print_report/1` to format the result
  for humans or `to_map/1` to get a JSON-encodable map for
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

    # Warmup, not measured.
    if config.warmup_iterations > 0 do
      run_workers(config, config.warmup_iterations, operation_fun, record_latency: false)
    end

    system_info = collect_system_info(config)

    :erlang.garbage_collect()
    pre_gc = :erlang.statistics(:garbage_collection)

    :msacc.reset()
    :msacc.start()
    sampler_pid = start_msacc_sampler(config.msacc_sample_interval_ms)

    started_at = DateTime.utc_now()
    start_monotonic = System.monotonic_time(:microsecond)

    {latencies, worker_results} =
      run_workers(config, config.iterations, operation_fun, record_latency: true)

    duration_us = System.monotonic_time(:microsecond) - start_monotonic

    # Snap the final accumulated counters BEFORE stopping msacc. The
    # periodic sampler is an optional debugging aid; for short runs it
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
      worker_results: worker_results,
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
  Returns a JSON-encodable map for the report. No Jason dep; callers
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
      ns_per_op: report.ns_per_op,
      latency_us: %{
        p50: report.p50_us,
        p90: report.p90_us,
        p99: report.p99_us,
        p99_9: report.p99_9_us,
        max: report.max_us
      },
      msacc: %{
        extended_mode: report.extended_msacc?,
        dirty_cpu: report.dirty_cpu,
        normal: report.normal
      },
      process_gc: %{
        count_delta: report.process_gc_count_delta,
        words_reclaimed_delta: report.process_gc_words_reclaimed_delta,
        absolute_gc_ns_per_op: report.absolute_gc_ns_per_op,
        absolute_dirty_gc_ns_per_op: report.absolute_dirty_gc_ns_per_op
      },
      per_worker_gc: report.per_worker_gc,
      system: report.system_info
    }
  end

  # --- Operation selection ------------------------------------------------

  defp derive_base_cell!(%Config{base_coord: coord, base_resolution: res}) do
    ExH3o.from_geo(coord, res)
  rescue
    ArgumentError ->
      reraise ArgumentError,
              "Could not derive base cell from #{inspect(coord)} at res #{res}",
              __STACKTRACE__
  end

  # ex_h3o dispatch --------------------------------------------------------

  defp build_operation(%Config{library: :ex_h3o, operation: :k_ring, k_ring_k: k}, cell) do
    fn -> ExH3o.k_ring(cell, k) end
  end

  defp build_operation(
         %Config{library: :ex_h3o, operation: :k_ring_distances, k_ring_k: k},
         cell
       ) do
    fn -> ExH3o.k_ring_distances(cell, k) end
  end

  defp build_operation(
         %Config{
           library: :ex_h3o,
           operation: :children,
           children_descent: descent,
           base_resolution: base
         },
         cell
       ) do
    target_res = min(base + descent, 15)
    fn -> ExH3o.children(cell, target_res) end
  end

  defp build_operation(%Config{library: :ex_h3o, operation: :compact} = config, cell) do
    target_res = min(config.base_resolution + 1, 15)
    dense_children = ExH3o.children(cell, target_res)
    fn -> ExH3o.compact(dense_children) end
  end

  defp build_operation(
         %Config{library: :ex_h3o, operation: :uncompact, base_resolution: base},
         cell
       ) do
    target_res = min(base + 1, 15)
    fn -> ExH3o.uncompact([cell], target_res) end
  end

  defp build_operation(
         %Config{
           library: :ex_h3o,
           operation: :polyfill,
           polyfill_vertices: vertices,
           polyfill_resolution: res
         },
         _cell
       ) do
    fn -> ExH3o.polyfill(vertices, res) end
  end

  defp build_operation(%Config{library: :ex_h3o, operation: :round_trip}, cell) do
    # Simple round-trip chain: to_geo -> get_resolution -> from_geo.
    # Every call allocates a {lat, lng} float tuple and a new cell
    # integer, exercising the "lots of small allocations on the calling
    # process heap" pattern we care about for GC measurements.
    fn ->
      {lat, lng} = ExH3o.to_geo(cell)
      res = ExH3o.get_resolution(cell)
      ExH3o.from_geo({lat, lng}, res)
    end
  end

  defp build_operation(%Config{library: :ex_h3o, operation: :null_nif}, _cell) do
    fn -> ExH3o.Native.null_nif() end
  end

  defp build_operation(%Config{library: :ex_h3o, operation: :null_nif_dirty}, _cell) do
    fn -> ExH3o.Native.null_nif_dirty() end
  end

  defp build_operation(%Config{library: :ex_h3o, operation: :is_valid}, cell) do
    fn -> ExH3o.is_valid(cell) end
  end

  defp build_operation(%Config{library: :ex_h3o, operation: :get_resolution}, cell) do
    fn -> ExH3o.get_resolution(cell) end
  end

  defp build_operation(
         %Config{library: :ex_h3o, operation: :from_geo, base_coord: coord, base_resolution: res},
         _cell
       ) do
    fn -> ExH3o.from_geo(coord, res) end
  end

  defp build_operation(%Config{library: :ex_h3o, operation: :to_geo}, cell) do
    fn -> ExH3o.to_geo(cell) end
  end

  defp build_operation(%Config{library: :ex_h3o, operation: :mixed_chain, k_ring_k: k}, _cell) do
    cells_tuple = List.to_tuple(mixed_chain_seed_cells())
    n = tuple_size(cells_tuple)

    fn ->
      cell = :erlang.element(next_mixed_chain_idx(n), cells_tuple)
      _ = ExH3o.k_ring(cell, k)
      _ = ExH3o.children(cell, 10)
      _ = ExH3o.parent(cell, 8)
      {lat, lng} = ExH3o.to_geo(cell)
      res = ExH3o.get_resolution(cell)
      ExH3o.from_geo({lat, lng}, res)
    end
  end

  # erlang-h3 dispatch -----------------------------------------------------
  #
  # The `:h3` library is only a `:dev`/`:test` dep, loaded via `mix run`
  # from bench/stress.exs. It returns bare values (no `{:ok, _}` tuples)
  # and uses a different polyfill polygon shape (`[[ring]]` nested list).

  defp build_operation(%Config{library: :erlang_h3, operation: :k_ring, k_ring_k: k}, cell) do
    fn -> :h3.k_ring(cell, k) end
  end

  defp build_operation(
         %Config{library: :erlang_h3, operation: :k_ring_distances, k_ring_k: k},
         cell
       ) do
    fn -> :h3.k_ring_distances(cell, k) end
  end

  defp build_operation(
         %Config{
           library: :erlang_h3,
           operation: :children,
           children_descent: descent,
           base_resolution: base
         },
         cell
       ) do
    target_res = min(base + descent, 15)
    fn -> :h3.children(cell, target_res) end
  end

  defp build_operation(%Config{library: :erlang_h3, operation: :compact} = config, cell) do
    target_res = min(config.base_resolution + 1, 15)
    dense_children = :h3.children(cell, target_res)
    fn -> :h3.compact(dense_children) end
  end

  defp build_operation(
         %Config{library: :erlang_h3, operation: :uncompact, base_resolution: base},
         cell
       ) do
    target_res = min(base + 1, 15)
    fn -> :h3.uncompact([cell], target_res) end
  end

  defp build_operation(
         %Config{
           library: :erlang_h3,
           operation: :polyfill,
           polyfill_vertices: vertices,
           polyfill_resolution: res
         },
         _cell
       ) do
    # erlang-h3 wraps the ring in an outer list so GeoJSON-style holes
    # can be passed alongside the outer ring.
    polygon = [vertices]
    fn -> :h3.polyfill(polygon, res) end
  end

  defp build_operation(%Config{library: :erlang_h3, operation: :round_trip}, cell) do
    fn ->
      {lat, lng} = :h3.to_geo(cell)
      res = :h3.get_resolution(cell)
      :h3.from_geo({lat, lng}, res)
    end
  end

  defp build_operation(%Config{library: :erlang_h3, operation: :null_nif}, _cell) do
    # erlang-h3 has no zero-work NIF, so use is_valid on a known-valid
    # cell as the closest equivalent baseline. Note this isn't truly
    # apples-to-apples (h3IsValid does a real bit check, ~3 ns of
    # work) but it's the smallest erlang-h3 NIF available.
    fn -> :h3.is_valid(617_700_169_957_507_071) end
  end

  defp build_operation(%Config{library: :erlang_h3, operation: :null_nif_dirty}, _cell) do
    # erlang-h3 has no dirty zero-work NIF. Use compact on a
    # single-cell input as the smallest dirty-CPU op available: a
    # one-element list round-trips through compact as a no-op, giving
    # us the minimal-cost dirty dispatch erlang-h3 exposes. (An empty
    # list works at runtime but violates erlang-h3's non-empty-list
    # typespec.)
    known_cell = [617_700_169_957_507_071]
    fn -> :h3.compact(known_cell) end
  end

  defp build_operation(%Config{library: :erlang_h3, operation: :is_valid}, cell) do
    fn -> :h3.is_valid(cell) end
  end

  defp build_operation(%Config{library: :erlang_h3, operation: :get_resolution}, cell) do
    fn -> :h3.get_resolution(cell) end
  end

  defp build_operation(
         %Config{
           library: :erlang_h3,
           operation: :from_geo,
           base_coord: coord,
           base_resolution: res
         },
         _cell
       ) do
    fn -> :h3.from_geo(coord, res) end
  end

  defp build_operation(%Config{library: :erlang_h3, operation: :to_geo}, cell) do
    fn -> :h3.to_geo(cell) end
  end

  defp build_operation(
         %Config{library: :erlang_h3, operation: :mixed_chain, k_ring_k: k},
         _cell
       ) do
    cells_tuple = List.to_tuple(mixed_chain_seed_cells())
    n = tuple_size(cells_tuple)

    fn ->
      cell = :erlang.element(next_mixed_chain_idx(n), cells_tuple)
      _ = :h3.k_ring(cell, k)
      _ = :h3.children(cell, 10)
      _ = :h3.parent(cell, 8)
      {lat, lng} = :h3.to_geo(cell)
      res = :h3.get_resolution(cell)
      :h3.from_geo({lat, lng}, res)
    end
  end

  # Derive seed cells from the city coordinates above. Called once per
  # build_operation/2 call, not per NIF call, so the derivation cost is
  # out of the measurement path.
  defp mixed_chain_seed_cells do
    Enum.map(@mixed_chain_seed_coords, fn {lat, lng} ->
      ExH3o.from_geo({lat, lng}, 9)
    end)
  end

  # Worker-local rotation counter stored in the process dict. Each
  # worker rotates through all N seed cells; different workers stay out
  # of phase because they start at different times and run at different
  # speeds. Returns a 1-based index for :erlang.element/2.
  defp next_mixed_chain_idx(n) do
    idx = Process.get(:mixed_chain_idx, 0)
    Process.put(:mixed_chain_idx, idx + 1)
    rem(idx, n) + 1
  end

  # --- Worker fan-out -----------------------------------------------------
  #
  # Two modes:
  #   * iteration mode (default): each worker runs `iterations` ops
  #   * duration mode: each worker runs ops until `duration_seconds`
  #     have elapsed (wall clock from the start of the worker)
  #
  # Worker results carry both the latency list AND a per-worker GC
  # snapshot (delta from before to after the loop) so the harness can
  # report distribution statistics, not just a single global counter.
  #
  # Returns `{[latency_us], [worker_result]}`. Worker results are nil
  # when warmup mode is active or per-worker GC tracking is disabled.

  defp run_workers(%Config{} = config, iterations, operation_fun, opts) do
    record? = Keyword.get(opts, :record_latency, true)
    track_gc? = record? and config.track_per_worker_gc
    duration_us = duration_us_or_nil(config)

    results =
      1..config.concurrency
      |> Task.async_stream(
        fn _worker_id ->
          run_worker_loop(operation_fun, iterations, duration_us, record?, track_gc?)
        end,
        max_concurrency: config.concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {Enum.flat_map(results, & &1.latencies), results}
  end

  defp duration_us_or_nil(%Config{duration_seconds: nil}), do: nil
  defp duration_us_or_nil(%Config{duration_seconds: secs}), do: secs * 1_000_000

  defp run_worker_loop(operation_fun, iterations, duration_us, record?, track_gc?) do
    pre_gc = if track_gc?, do: snapshot_process_gc(), else: nil
    latencies = collect_latencies(operation_fun, iterations, duration_us, record?)
    post_gc = if track_gc?, do: snapshot_process_gc(), else: nil

    %{latencies: latencies, pre_gc: pre_gc, post_gc: post_gc, op_count: length(latencies)}
  end

  defp collect_latencies(fun, _iterations, duration_us, true) when not is_nil(duration_us),
    do: duration_loop_with_latencies(fun, duration_us, [])

  defp collect_latencies(fun, _iterations, duration_us, false) when not is_nil(duration_us) do
    duration_loop(fun, duration_us)
    []
  end

  defp collect_latencies(fun, iterations, nil, true),
    do: iteration_loop_with_latencies(fun, iterations, [])

  defp collect_latencies(fun, iterations, nil, false) do
    iteration_loop(fun, iterations)
    []
  end

  defp iteration_loop(_fun, 0), do: :ok

  defp iteration_loop(fun, n) do
    fun.()
    iteration_loop(fun, n - 1)
  end

  defp iteration_loop_with_latencies(_fun, 0, acc), do: acc

  defp iteration_loop_with_latencies(fun, n, acc) do
    t0 = System.monotonic_time(:microsecond)
    _ = fun.()
    elapsed = System.monotonic_time(:microsecond) - t0
    iteration_loop_with_latencies(fun, n - 1, [elapsed | acc])
  end

  defp duration_loop(fun, duration_us) do
    deadline = System.monotonic_time(:microsecond) + duration_us
    do_duration_loop(fun, deadline)
  end

  defp do_duration_loop(fun, deadline) do
    if System.monotonic_time(:microsecond) >= deadline do
      :ok
    else
      fun.()
      do_duration_loop(fun, deadline)
    end
  end

  defp duration_loop_with_latencies(fun, duration_us, acc) do
    deadline = System.monotonic_time(:microsecond) + duration_us
    do_duration_loop_with_latencies(fun, deadline, acc)
  end

  defp do_duration_loop_with_latencies(fun, deadline, acc) do
    t0 = System.monotonic_time(:microsecond)

    if t0 >= deadline do
      acc
    else
      _ = fun.()
      elapsed = System.monotonic_time(:microsecond) - t0
      do_duration_loop_with_latencies(fun, deadline, [elapsed | acc])
    end
  end

  # The `:garbage_collection` key on Process.info returns a keyword list
  # that includes `:minor_gcs`, a monotonic counter of GC events on this
  # specific process. (`:garbage_collection_info` is a different key that
  # only carries current heap sizes, no event counter.) The snapshot
  # captures everything we want to diff post-run.
  defp snapshot_process_gc do
    info =
      Process.info(self(), [
        :garbage_collection,
        :total_heap_size,
        :heap_size,
        :memory
      ])

    gc_kwl = Keyword.get(info, :garbage_collection, [])

    %{
      minor_gcs: Keyword.get(gc_kwl, :minor_gcs, 0),
      total_heap_size: Keyword.get(info, :total_heap_size, 0),
      heap_size: Keyword.get(info, :heap_size, 0),
      memory: Keyword.get(info, :memory, 0)
    }
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
      worker_results: worker_results,
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

    ns_per_op =
      if total_ops > 0 do
        duration_us * 1_000 * config.concurrency / total_ops
      else
        0.0
      end

    percentiles = compute_percentiles(latencies)

    dirty_breakdown = scheduler_breakdown(msacc_data, @dirty_cpu)
    normal_breakdown = scheduler_breakdown(msacc_data, @normal)
    extended? = dirty_breakdown.extended? or normal_breakdown.extended?

    # Absolute GC time per op:
    #
    #   normal scheduler:
    #     gc_pct/100 * wall_time_us * normal_thread_count / total_ops
    #     → because process GC happens on whichever normal scheduler the
    #       calling worker is currently bound to, and we summed across
    #       all normal scheduler threads
    #
    #   dirty scheduler:
    #     gc_pct/100 * wall_time_us * dirty_thread_count / total_ops
    #     → mirrors the same logic for ops that ran on dirty schedulers
    #
    # Output is nanoseconds per op, the unit that's actually meaningful
    # for the swap decision. The report previously only carried gc_pct,
    # which was an apples-to-oranges comparison when the two libraries
    # had wildly different wall clocks.
    absolute_gc_ns_per_op =
      absolute_gc_ns_per_op(normal_breakdown, duration_us, total_ops)

    absolute_dirty_gc_ns_per_op =
      absolute_gc_ns_per_op(dirty_breakdown, duration_us, total_ops)

    per_worker_gc =
      if config.track_per_worker_gc do
        aggregate_per_worker_gc(worker_results)
      else
        nil
      end

    %Report{
      config: config,
      started_at: started_at,
      duration_ms: div(duration_us, 1000),
      total_ops: total_ops,
      ops_per_sec: Float.round(ops_per_sec, 2),
      ns_per_op: Float.round(ns_per_op, 2),
      p50_us: percentiles.p50,
      p90_us: percentiles.p90,
      p99_us: percentiles.p99,
      p99_9_us: percentiles.p99_9,
      max_us: percentiles.max,
      dirty_cpu: strip_extended(dirty_breakdown),
      normal: strip_extended(normal_breakdown),
      extended_msacc?: extended?,
      process_gc_count_delta: gc_count_delta,
      process_gc_words_reclaimed_delta: gc_words_delta,
      absolute_gc_ns_per_op: absolute_gc_ns_per_op,
      absolute_dirty_gc_ns_per_op: absolute_dirty_gc_ns_per_op,
      per_worker_gc: per_worker_gc,
      system_info: system_info
    }
  end

  defp absolute_gc_ns_per_op(_breakdown, _duration_us, 0), do: 0.0

  defp absolute_gc_ns_per_op(%{gc_pct: +0.0}, _duration_us, _total_ops), do: 0.0

  defp absolute_gc_ns_per_op(breakdown, duration_us, total_ops) do
    gc_us = breakdown.gc_pct / 100 * duration_us * breakdown.thread_count
    Float.round(gc_us * 1_000 / total_ops, 2)
  end

  defp aggregate_per_worker_gc(worker_results) do
    worker_results
    |> Enum.filter(fn %{pre_gc: pre, post_gc: post} -> pre != nil and post != nil end)
    |> case do
      [] ->
        nil

      tracked ->
        deltas =
          Enum.map(tracked, fn %{pre_gc: pre, post_gc: post} ->
            %{
              gc_count: max(post.minor_gcs - pre.minor_gcs, 0),
              heap_growth: post.total_heap_size - pre.total_heap_size,
              memory_growth: post.memory - pre.memory
            }
          end)

        gc_counts = Enum.map(deltas, & &1.gc_count)
        heaps = Enum.map(deltas, & &1.heap_growth)
        mems = Enum.map(deltas, & &1.memory_growth)
        n = length(deltas)

        %{
          workers: n,
          gc_count_total: Enum.sum(gc_counts),
          gc_count_avg: Float.round(Enum.sum(gc_counts) / n, 2),
          gc_count_max: Enum.max(gc_counts),
          heap_growth_words_total: Enum.sum(heaps),
          heap_growth_words_avg: Float.round(Enum.sum(heaps) / n, 2),
          heap_growth_words_max: Enum.max(heaps),
          memory_growth_bytes_total: Enum.sum(mems),
          memory_growth_bytes_avg: Float.round(Enum.sum(mems) / n, 2),
          memory_growth_bytes_max: Enum.max(mems)
        }
    end
  end

  defp strip_extended(breakdown) do
    Map.drop(breakdown, [:extended?])
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

  defp scheduler_breakdown(msacc_data, type) do
    msacc_data
    |> Enum.filter(&(&1.type == type))
    |> summarize_threads()
  end

  defp summarize_threads([]) do
    %{
      gc_pct: 0.0,
      emulator_pct: 0.0,
      sleep_pct: 0.0,
      nif_pct: nil,
      thread_count: 0,
      extended?: false
    }
  end

  defp summarize_threads([first | _] = threads) do
    extended? = Map.has_key?(first.counters, :nif)
    totals = sum_thread_counters(threads)
    total_time = totals |> Map.values() |> Enum.sum() |> max(1)

    gc_time = Map.get(totals, :gc, 0) + Map.get(totals, :gc_fullsweep, 0)
    emulator_time = Map.get(totals, :emulator, 0)
    sleep_time = Map.get(totals, :sleep, 0)

    %{
      gc_pct: pct(gc_time, total_time),
      emulator_pct: pct(emulator_time, total_time),
      sleep_pct: pct(sleep_time, total_time),
      nif_pct: if(extended?, do: pct(Map.get(totals, :nif, 0), total_time), else: nil),
      thread_count: length(threads),
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

  @spec format_report(Report.t()) :: String.t()
  defp format_report(%Report{} = report) do
    config = report.config
    verdict = gc_verdict(report)

    """

    ============================================================
     stress harness: #{config.library} / #{config.operation}
    ============================================================

    Configuration
    -------------
      library:         #{config.library}
      operation:       #{config.operation}
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
      avg ns/op:       #{report.ns_per_op} (avg wall-time per op per worker)

    Latency (microseconds)
    ----------------------
      p50:             #{report.p50_us}
      p90:             #{report.p90_us}
      p99:             #{report.p99_us}
      p99.9:           #{report.p99_9_us}
      max:             #{report.max_us}
    #{format_scheduler_block("Dirty CPU scheduler", report.dirty_cpu, report.extended_msacc?)}
    #{format_scheduler_block("Normal scheduler", report.normal, report.extended_msacc?)}
    Process-level GC
    ----------------
      collections:     #{report.process_gc_count_delta}
      words reclaimed: #{report.process_gc_words_reclaimed_delta}

    Absolute GC time per op
    -----------------------
      normal sched:    #{report.absolute_gc_ns_per_op} ns/op
      dirty sched:     #{report.absolute_dirty_gc_ns_per_op} ns/op
    #{format_per_worker_gc(report.per_worker_gc)}
    Verdict
    -------
      #{verdict}
    """
  end

  defp format_per_worker_gc(nil), do: "\n"

  defp format_per_worker_gc(stats) do
    """

    Per-worker GC distribution (#{stats.workers} workers)
    -----------------------------------------------------
      gc count:        avg=#{stats.gc_count_avg}  max=#{stats.gc_count_max}  total=#{stats.gc_count_total}
      heap growth:     avg=#{stats.heap_growth_words_avg} words  max=#{stats.heap_growth_words_max} words
      memory growth:   avg=#{format_bytes(stats.memory_growth_bytes_avg)}  max=#{format_bytes(stats.memory_growth_bytes_max)}
    """
  end

  defp format_bytes(n) when is_number(n) do
    abs_n = abs(n)

    cond do
      abs_n >= 1_048_576 -> "#{Float.round(n / 1_048_576, 2)} MiB"
      abs_n >= 1_024 -> "#{Float.round(n / 1_024, 2)} KiB"
      true -> "#{n} B"
    end
  end

  defp format_scheduler_block(label, breakdown, extended?) do
    nif_line =
      cond do
        extended? and is_number(breakdown.nif_pct) ->
          "  nif%:            #{breakdown.nif_pct}%\n"

        extended? ->
          "  nif%:            0.0% (no NIF time observed)\n"

        true ->
          "  nif%:            not available (default msacc build)\n"
      end

    """

    #{label} (aggregate across #{breakdown.thread_count} threads)
    ---------------------------------------------
      gc%:             #{breakdown.gc_pct}%
      emulator%:       #{breakdown.emulator_pct}%
      sleep%:          #{breakdown.sleep_pct}%
    #{nif_line}\
    """
  end

  # The target symptom is dirty-CPU-scheduler GC misattribution. When a
  # NIF runs on a dirty scheduler and allocates terms, GC work gets
  # attributed to the dirty thread instead of the calling process. The
  # signal is dirty_cpu gc% climbing above ~20%. For ops that run on
  # the normal scheduler we still want to track process-level GC
  # pressure but the msacc signal is different. It shows up as
  # normal_scheduler gc% + process GC count/words delta.
  defp gc_verdict(%Report{dirty_cpu: %{gc_pct: dirty_gc}}) when dirty_gc >= 50.0,
    do: "dirty_cpu gc% #{dirty_gc}%: SEVERE, dirty schedulers burning on GC instead of NIF work"

  defp gc_verdict(%Report{dirty_cpu: %{gc_pct: dirty_gc}}) when dirty_gc >= 20.0,
    do: "dirty_cpu gc% #{dirty_gc}%: HIGH, dirty-scheduler GC-misattribution symptom present"

  defp gc_verdict(%Report{dirty_cpu: %{gc_pct: dirty_gc}, normal: %{gc_pct: normal_gc}})
       when normal_gc >= 20.0,
       do: "normal gc% #{normal_gc}%: HIGH (dirty_cpu clean at #{dirty_gc}%)"

  defp gc_verdict(%Report{dirty_cpu: %{gc_pct: d}, normal: %{gc_pct: n}}),
    do: "dirty_cpu gc% #{d}%, normal gc% #{n}%: within normal range"
end
