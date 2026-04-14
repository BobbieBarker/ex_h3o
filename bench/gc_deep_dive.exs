#
# GC deep-dive: side-by-side honest comparison of ex_h3o vs erlang-h3
#
# Runs each library through the same set of operations under identical
# concurrency and reports the numbers that actually matter for a swap
# decision:
#
#   * avg ns per op (worker-side latency)
#   * absolute GC time per op (ns, NOT percentage)
#   * per-worker GC count (avg/max across workers)
#   * per-worker heap growth (max bytes any single worker added)
#
# Percentage-based GC numbers (gc%) are misleading when the two libraries
# have wildly different wall clocks. A slow library will show a low gc%
# just because it spent more wall time in non-GC work. Absolute ns/op is
# the apples-to-apples comparison.
#
# Default duration: 30 seconds per cell, override with `--duration N`.
# Concurrency defaults to 100, high enough to saturate the default
# 10-scheduler BEAM and surface queueing effects.
#
# Usage:
#
#   mix run bench/gc_deep_dive.exs
#   mix run bench/gc_deep_dive.exs -- --duration 60 --concurrency 200
#   mix run bench/gc_deep_dive.exs -- --only k_ring,polyfill,mixed_chain

priv_path = Path.join([File.cwd!(), "priv/ex_h3o_nif.so"])

unless File.exists?(priv_path) do
  IO.puts(:stderr, "ERROR: missing priv/ex_h3o_nif.so. Run `mix compile --force` first")
  System.halt(1)
end

# `mix run script.exs -- --flag value` passes ["--", "--flag", "value"]
# in System.argv(). OptionParser stops at "--" so we strip it.
argv =
  case System.argv() do
    ["--" | rest] -> rest
    other -> other
  end

{opts, _, _} =
  OptionParser.parse(argv,
    strict: [
      duration: :integer,
      concurrency: :integer,
      only: :string,
      iterations: :integer
    ]
  )

duration = Keyword.get(opts, :duration, 30)
concurrency = Keyword.get(opts, :concurrency, 100)
fixed_iterations = Keyword.get(opts, :iterations)

# Operations in display order. Each row labels the test, picks an
# operation atom, and any operation-specific config overrides.
all_ops = [
  {"null_nif", :null_nif, []},
  {"is_valid", :is_valid, []},
  {"get_resolution", :get_resolution, []},
  {"from_geo", :from_geo, []},
  {"to_geo", :to_geo, []},
  {"k_ring(2)", :k_ring, [k_ring_k: 2]},
  {"k_ring(10)", :k_ring, [k_ring_k: 10]},
  {"children(+2)", :children, [children_descent: 2]},
  {"polyfill", :polyfill, []},
  {"mixed_chain", :mixed_chain, [k_ring_k: 2]}
]

selected =
  case Keyword.get(opts, :only) do
    nil ->
      all_ops

    csv ->
      wanted = csv |> String.split(",") |> Enum.map(&String.trim/1) |> MapSet.new()

      Enum.filter(all_ops, fn {label, op, _} ->
        MapSet.member?(wanted, label) or MapSet.member?(wanted, Atom.to_string(op))
      end)
  end

if selected == [] do
  IO.puts(:stderr, "No operations selected. Check --only filter")
  System.halt(1)
end

IO.puts("""

============================================================
  ex_h3o GC deep-dive: side-by-side library comparison
============================================================

Configuration:
  concurrency:       #{concurrency}
  per-cell duration: #{if fixed_iterations, do: "iterations=#{fixed_iterations}", else: "#{duration}s"}
  warmup:            500 iterations per worker
  ops:               #{Enum.map_join(selected, ", ", fn {label, _, _} -> label end)}

This run will take roughly #{length(selected) * 2 * if(fixed_iterations, do: 5, else: duration + 2)} seconds.
""")

run_one = fn library, op_atom, extra_opts ->
  base = [
    library: library,
    operation: op_atom,
    concurrency: concurrency,
    warmup_iterations: 500,
    track_per_worker_gc: true
  ]

  base =
    if fixed_iterations do
      Keyword.put(base, :iterations, fixed_iterations)
    else
      base
      |> Keyword.put(:duration_seconds, duration)
      # iterations is required by Config but ignored in duration mode;
      # set it high enough that an unexpected fall-through to iteration
      # mode would be obviously wrong rather than silently fast.
      |> Keyword.put(:iterations, 10_000_000)
    end

  config = ExH3o.Stress.Config.new(base ++ extra_opts)
  ExH3o.Stress.Harness.run(config)
end

# Collect all rows first so we can render the comparison table at the end.
rows =
  Enum.flat_map(selected, fn {label, op_atom, extra} ->
    IO.write("  running #{label} ex_h3o ... ")
    ex = run_one.(:ex_h3o, op_atom, extra)
    IO.puts("done (#{ex.total_ops} ops)")

    IO.write("  running #{label} erlang_h3 ... ")
    h3 = run_one.(:erlang_h3, op_atom, extra)
    IO.puts("done (#{h3.total_ops} ops)")

    [{label, :ex_h3o, ex}, {label, :erlang_h3, h3}]
  end)

# ---------- Renderers ----------

format_ns = fn
  n when is_number(n) and n >= 1_000_000 ->
    :io_lib.format("~.2f ms", [n / 1_000_000]) |> IO.iodata_to_binary()

  n when is_number(n) and n >= 1_000 ->
    :io_lib.format("~.2f us", [n / 1_000]) |> IO.iodata_to_binary()

  n when is_number(n) ->
    :io_lib.format("~.2f ns", [n / 1.0]) |> IO.iodata_to_binary()
end

format_bytes = fn
  n when is_number(n) and n >= 1_048_576 ->
    :io_lib.format("~.2f MiB", [n / 1_048_576]) |> IO.iodata_to_binary()

  n when is_number(n) and n >= 1_024 ->
    :io_lib.format("~.2f KiB", [n / 1_024]) |> IO.iodata_to_binary()

  n when is_number(n) ->
    "#{n} B"
end

# Pivot rows by operation label so we can print both libraries on one line.
by_label =
  rows
  |> Enum.group_by(fn {label, _, _} -> label end)
  |> Enum.map(fn {label, [_ | _] = pair} ->
    map = Map.new(pair, fn {_l, lib, r} -> {lib, r} end)
    {label, Map.get(map, :ex_h3o), Map.get(map, :erlang_h3)}
  end)
  |> Enum.sort_by(fn {label, _, _} -> Enum.find_index(selected, &(elem(&1, 0) == label)) end)

schedulers = System.schedulers_online()

# CPU ns per call ≈ (num schedulers) / ops_per_sec, in nanoseconds.
# When workers >> schedulers and the CPU is saturated, this approximates
# the actual single-thread cost per call. Lower is better; this is the
# number that maps most directly to "what would this op cost on a busy
# server".
cpu_ns_per_call = fn ops_per_sec ->
  if ops_per_sec > 0, do: schedulers * 1_000_000_000 / ops_per_sec, else: 0.0
end

IO.puts("""

============================================================
  Throughput + latency  (#{schedulers} schedulers)
============================================================

  operation          library      ops/sec        cpu ns/call    p50      p99      p99.9    max
  ----------------   ---------    -----------    -----------    ------   ------   ------   ------
""")

Enum.each(by_label, fn {label, ex, h3} ->
  format_row = fn lib_name, r ->
    cpu = cpu_ns_per_call.(r.ops_per_sec)

    "  #{String.pad_trailing(label, 18)} #{String.pad_trailing(lib_name, 12)} " <>
      "#{String.pad_trailing(:erlang.float_to_binary(r.ops_per_sec / 1.0, decimals: 0), 14)} " <>
      "#{String.pad_trailing(format_ns.(cpu), 14)} " <>
      "#{String.pad_trailing("#{r.p50_us}us", 8)} " <>
      "#{String.pad_trailing("#{r.p99_us}us", 8)} " <>
      "#{String.pad_trailing("#{r.p99_9_us}us", 8)} " <>
      "#{String.pad_trailing("#{r.max_us}us", 8)}"
  end

  IO.puts(format_row.("ex_h3o", ex))
  IO.puts(format_row.("erlang_h3", h3))
  IO.puts("")
end)

IO.puts("""

============================================================
  GC pressure - absolute, not percentage
============================================================

  operation          library      gc ns/op       dirty gc ns/op    process gcs    worker gc avg/max    worker heap max
  ----------------   ---------    ----------    ---------------    -----------    ------------------   ----------------
""")

Enum.each(by_label, fn {label, ex, h3} ->
  format_row = fn lib_name, r ->
    pw = r.per_worker_gc || %{gc_count_avg: 0.0, gc_count_max: 0, heap_growth_words_max: 0}

    "  #{String.pad_trailing(label, 18)} #{String.pad_trailing(lib_name, 12)} " <>
      "#{String.pad_trailing(format_ns.(r.absolute_gc_ns_per_op), 13)} " <>
      "#{String.pad_trailing(format_ns.(r.absolute_dirty_gc_ns_per_op), 18)} " <>
      "#{String.pad_trailing("#{r.process_gc_count_delta}", 14)} " <>
      "#{String.pad_trailing("#{pw.gc_count_avg}/#{pw.gc_count_max}", 20)} " <>
      "#{format_bytes.(pw.heap_growth_words_max * 8)}"
  end

  IO.puts(format_row.("ex_h3o", ex))
  IO.puts(format_row.("erlang_h3", h3))
  IO.puts("")
end)

IO.puts("""

============================================================
  Verdict per operation (negative numbers = ex_h3o is better)
============================================================
""")

Enum.each(by_label, fn {label, ex, h3} ->
  ex_cpu = cpu_ns_per_call.(ex.ops_per_sec)
  h3_cpu = cpu_ns_per_call.(h3.ops_per_sec)
  speed_ratio = if h3_cpu > 0, do: ex_cpu / h3_cpu, else: 0.0

  gc_ratio =
    if h3.absolute_gc_ns_per_op > 0,
      do: ex.absolute_gc_ns_per_op / h3.absolute_gc_ns_per_op,
      else: 0.0

  speed_str =
    cond do
      speed_ratio <= 0.0 -> "n/a"
      speed_ratio < 1.0 -> "#{Float.round(1.0 / speed_ratio, 2)}x FASTER"
      true -> "#{Float.round(speed_ratio, 2)}x slower"
    end

  gc_str =
    cond do
      gc_ratio <= 0.0 -> "n/a"
      gc_ratio < 1.0 -> "#{Float.round(1.0 / gc_ratio, 2)}x LESS GC"
      true -> "#{Float.round(gc_ratio, 2)}x MORE GC"
    end

  IO.puts(
    "  #{String.pad_trailing(label, 18)}  speed: #{String.pad_trailing(speed_str, 18)}  gc: #{gc_str}"
  )
end)

IO.puts("""

Notes
-----
  * "cpu ns/call" = schedulers / ops_per_sec, the closest proxy to actual single-thread CPU cost
    when schedulers are saturated. Lower = better.
  * "speed" verdict compares cpu ns/call between libraries.
  * "gc" verdict compares absolute_gc_ns_per_op (normal-scheduler GC time charged per op).
    Lower = better.
  * Per-worker heap_growth_words_max shows how much memory a single worker added during the run.
    A blown-up max relative to avg means GC pressure is concentrated in a few processes.
  * Process gcs is the global counter (includes harness + supervisors); worker gc avg/max
    is the per-worker view; that's the one to trust for "do worker processes thrash GC".
  * For the swap decision: any operation where ex_h3o is faster AND has equal-or-less GC ns/op
    is a clear win. Anywhere ex_h3o is slower OR has more GC ns/op needs separate justification.
""")
