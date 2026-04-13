# msacc Stress Testing Reference

Reference for writing GC stress tests using Erlang's microstate accounting (`msacc`). This document is grounded in the [official msacc documentation](https://www.erlang.org/doc/apps/runtime_tools/msacc.html) and OTP source.

## What msacc Measures

msacc tracks how each BEAM thread spends its time, broken down by **state** (gc, emulator, sleep, etc.) and **thread type** (scheduler, dirty_cpu_scheduler, dirty_io_scheduler, async, aux, poll).

This is the correct instrument for measuring NIF GC pressure. Benchee measures throughput; msacc measures *what the scheduler threads are doing* — specifically, how much time dirty CPU schedulers spend in garbage collection vs useful work.

## API Reference

All functions are in the `:msacc` module (from the `runtime_tools` application).

### Control

```elixir
:msacc.available()    # => boolean — is msacc compiled in?
:msacc.start()        # => boolean — enable, returns previous state
:msacc.stop()         # => boolean — disable, returns previous state
:msacc.reset()        # => boolean — clear all counters, returns previous state
:msacc.start(2000)    # => true — reset, enable, sleep 2000ms, stop (convenience)
```

### Data Retrieval

```elixir
:msacc.stats()        # => msacc_data — list of per-thread maps, counters in MICROSECONDS
```

Each element in the list is a map:

```elixir
%{
  type: :dirty_cpu_scheduler,   # thread type atom
  id: 1,                        # thread id (integer)
  counters: %{                  # state => microseconds
    gc: 45_000,
    emulator: 900_000,
    sleep: 50_000,
    # ... other states
  }
}
```

### Analysis

```elixir
:msacc.stats(:realtime, data)   # => per-thread percentage breakdowns (% of elapsed time)
:msacc.stats(:runtime, data)    # => per-thread percentage breakdowns (% of work time, excludes sleep)
:msacc.stats(:type, data)       # => merge threads of same type together
```

### Output

```elixir
:msacc.print()                         # print current stats to stdout
:msacc.print(data)                     # print specific data
:msacc.print(data, %{system: true})    # include system-wide percentages
:msacc.to_file("msacc_output.txt")     # save to file
data = :msacc.from_file("msacc_output.txt")  # load from file
```

## Thread Types

| Type | Description | Count |
|------|-------------|-------|
| `scheduler` | Normal BEAM schedulers | N (one per CPU core) |
| `dirty_cpu_scheduler` | Dirty CPU-bound schedulers | N (one per CPU core, default) |
| `dirty_io_scheduler` | Dirty I/O schedulers | 10 (default) |
| `async` | Async thread pool | configurable |
| `aux` | Auxiliary threads | 1 |
| `poll` | I/O polling thread | 1 |

For NIF GC stress testing, filter for `type: :dirty_cpu_scheduler`.

## States: Basic vs Extended Mode

**This is critical.** msacc has two state sets, determined at BEAM **compile time**:

### Basic Mode (default OTP build: `--with-microstate-accounting=yes`)

7 states: `aux`, `check_io`, `emulator`, `gc`, `other`, `port`, `sleep`

- `gc` — garbage collection (minor + major combined)
- `emulator` — executing BEAM code **and NIFs** (lumped together)
- `sleep` — idle, no work available

### Extended Mode (`--with-microstate-accounting=extra`)

15 states: `alloc`, `aux`, `bif`, `busy_wait`, `check_io`, `emulator`, `ets`, `gc`, `gc_fullsweep`, `nif`, `other`, `port`, `send`, `sleep`, `timers`

- `gc` — minor/generational garbage collection
- `gc_fullsweep` — full-sweep garbage collection
- `nif` — executing NIF code specifically
- `emulator` — executing BEAM bytecode only (NIFs separated out)

### Implications for Stress Testing

On a **default OTP build**, you can measure `gc%` but NIF execution time is inside `emulator%`. The ratio `gc / (gc + emulator)` on dirty CPU scheduler threads still indicates GC pressure — a dirty scheduler running NIFs should spend most time in `emulator` (which includes NIF time), not `gc`.

On an **extended build**, you get the precise `nif%` vs `gc%` breakdown. This is more informative but requires a custom BEAM build.

**Our stress test must work on default builds.** Use `gc%` as the primary signal. On dirty CPU schedulers:
- **Healthy**: high `emulator%`, low `gc%`, low `sleep%` — the scheduler is doing useful work
- **GC pressure**: high `gc%` relative to `emulator%` — the scheduler is spending time cleaning up term allocations instead of running NIFs

Check which mode is active:

```elixir
# If :nif is a key in any thread's counters, we're in extended mode
[first | _] = :msacc.stats()
extended? = Map.has_key?(first.counters, :nif)
```

## Sampling Pattern

The stress test samples msacc data periodically during a load phase. Do NOT use `:msacc.start(time)` — it blocks the calling process. Instead:

```elixir
defp start_msacc_sampler do
  :msacc.reset()
  :msacc.start()
  parent = self()
  spawn(fn -> msacc_sample_loop(parent, []) end)
end

defp stop_msacc_sampler(pid) do
  :msacc.stop()
  send(pid, {:stop, self()})
  receive do
    {:samples, data} -> data
  after
    3_000 -> []
  end
end

defp msacc_sample_loop(parent, acc) do
  receive do
    {:stop, caller} -> send(caller, {:samples, Enum.reverse(acc)})
  after
    100 ->  # sample every 100ms
      msacc_sample_loop(parent, [:msacc.stats() | acc])
  end
end
```

Use the **last sample** for analysis — it has the most accumulated counter time and best represents the steady-state behavior.

## Extracting Dirty CPU GC Percentage

```elixir
defp dirty_cpu_gc_percentage(msacc_data) do
  dirty_threads = Enum.filter(msacc_data, &(&1.type == :dirty_cpu_scheduler))

  if dirty_threads == [] do
    {:error, :no_dirty_cpu_threads}
  else
    # Aggregate counters across all dirty CPU threads
    totals = Enum.reduce(dirty_threads, %{}, fn thread, acc ->
      Map.merge(acc, thread.counters, fn _k, a, b -> a + b end)
    end)

    total_time = totals |> Map.values() |> Enum.sum() |> max(1)
    gc_time = Map.get(totals, :gc, 0) + Map.get(totals, :gc_fullsweep, 0)
    gc_pct = Float.round(gc_time / total_time * 100, 2)

    {:ok, gc_pct}
  end
end
```

Note: `gc_fullsweep` only exists in extended mode. On default builds, `Map.get(totals, :gc_fullsweep, 0)` safely returns 0.

## Stress Test Structure

A well-structured stress test has these phases:

1. **System info** — report scheduler counts, msacc mode (basic/extended), OTP version
2. **Warmup** — run the workload briefly without measuring (primes caches, JIT, NIF loading)
3. **Baseline GC snapshot** — capture `:erlang.statistics(:garbage_collection)` before load
4. **Load phase** — run concurrent workers calling the target functions, with msacc sampling running in parallel
5. **Post-load GC snapshot** — capture GC stats after load
6. **Reporting** — compute and display gc%, throughput, latency percentiles

### Concurrent Load Pattern

```elixir
defp run_concurrent_load(opts) do
  concurrency = opts[:concurrency]

  1..concurrency
  |> Task.async_stream(
    fn i -> run_worker(i, opts) end,
    max_concurrency: concurrency,
    timeout: :infinity,
    ordered: false
  )
  |> Enum.flat_map(fn {:ok, latencies} -> latencies end)
end
```

### Per-Operation Timing

```elixir
defp timed(fun) do
  t0 = System.monotonic_time(:microsecond)
  fun.()
  System.monotonic_time(:microsecond) - t0
end
```

### Configurable Pressure Knobs

The test must be tunable without code changes:

| Parameter | Purpose | Effect |
|-----------|---------|--------|
| `concurrency` | Number of concurrent worker processes | More workers = more contention for dirty schedulers |
| `iterations` | Operations per worker | Longer sustained load |
| `k_ring_k` | k value for k_ring calls | Higher k = more cells returned = more allocation pressure |
| `warmup_iterations` | Iterations before measurement | Stabilize JIT, caches |

## Process-Level GC Stats

Complement msacc with process-level GC statistics:

```elixir
{gc_count, words_reclaimed, _} = :erlang.statistics(:garbage_collection)
```

This gives total GC runs and words reclaimed across all processes. Take a snapshot before and after the load phase; the delta shows total GC work during the test.

## Reporting Format

Report should include:

1. **Configuration**: concurrency, iterations, k values, scheduler counts, msacc mode
2. **Throughput**: total calls, wall time, calls/sec
3. **Latency percentiles**: p50, p90, p99, p99.9, max (per-operation microseconds)
4. **Process-level GC**: total collections, words reclaimed during load
5. **msacc dirty CPU breakdown**: per-thread and aggregate gc%, emulator% (or nif% in extended mode), sleep%
6. **Verdict**: gc% assessment with threshold guidance

### Threshold Guidance

- `gc% < 5%` on dirty CPU threads — excellent, minimal GC pressure
- `gc% 5-20%` — moderate, acceptable for heavy workloads
- `gc% > 20%` — high GC pressure, investigate term allocation patterns
- `gc% > 50%` — severe, dirty schedulers are spending more time in GC than useful work

These thresholds are guidelines, not hard rules. The primary criterion is *relative*: ex_h3o's gc% should be measurably lower than erlang-h3's under the same parameters.

## Common Mistakes

1. **Using `:msacc.start(time)` during load** — this blocks the calling process for `time` ms. Use `start/0` + `stop/0` with a separate sampler process instead.
2. **Assuming `nif` state exists** — only available in extended mode builds. Always check and fall back to `emulator` on default builds.
3. **Sampling too frequently** — `:msacc.stats()` has overhead. 100ms intervals are sufficient; don't poll every 1ms.
4. **Forgetting `:msacc.reset()`** — counters accumulate across start/stop cycles. Reset before each measurement phase.
5. **Running on a quiet system** — dirty CPU schedulers show high `sleep%` when idle. The stress test must generate enough load to keep them busy for meaningful gc% readings.
6. **Comparing across different machines** — absolute numbers vary. Always compare ex_h3o vs erlang-h3 on the same machine in the same session.
