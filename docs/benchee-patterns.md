# Benchee Patterns for NIF Libraries

Reference for writing benchmarks with [Benchee](https://hexdocs.pm/benchee/readme.html) (v1.5+) in NIF-backed Elixir libraries. Grounded in [Benchee hexdocs](https://hexdocs.pm/benchee/Benchee.html) and [Benchee source](https://github.com/bencheeorg/benchee).

## What Benchee Can and Cannot Measure for NIFs

### Can Measure Accurately

- **Throughput (IPS)** — iterations per second, the primary metric for comparing implementations
- **Run time statistics** — average, median, standard deviation, percentiles (p50, p99 configurable), min, max
- **BEAM-side memory allocation** — memory allocated on the BEAM process heap during execution (via `memory_time` option)
- **Relative comparison** — "implementation A is 2.15x slower than B"

### Cannot Measure

- **NIF-side memory** — memory allocated in Rust/C heap (`malloc`, `OwnedBinary::new`, `Vec::push`) is invisible to Benchee. It only tracks BEAM process heap via `:erlang.trace/3` GC events. ([source](https://github.com/bencheeorg/benchee/blob/main/lib/benchee/benchmark/measure/memory.ex))
- **Reductions for NIFs** — Benchee's `reduction_time` option explicitly warns: "BIFs & NIFs are not accurately tracked." ([source](https://hexdocs.pm/benchee/readme.html))
- **Dirty scheduler behavior** — Benchee has no visibility into scheduler thread states. Use msacc for this. See `docs/msacc-stress-testing.md`.

### Key Insight

Benchee tells you *how fast* something is. msacc tells you *why* it's fast or slow at the scheduler level. For NIF boundary validation, you need both.

## Configuration Reference

```elixir
Benchee.run(
  %{
    "scenario_name" => fn input -> do_work(input) end,
    "other_scenario" => fn input -> do_other_work(input) end
  },
  warmup: 2,              # seconds — warmup before measuring (default: 2)
  time: 5,                # seconds — measurement duration (default: 5)
  memory_time: 2,         # seconds — memory measurement duration (default: 0 = disabled)
  reduction_time: 0,      # seconds — DO NOT USE for NIFs (inaccurate)
  parallel: 1,            # concurrent processes per scenario (default: 1)
  inputs: %{...},         # named inputs (see below)
  formatters: [...],      # output formatters (see below)
  pre_check: true,        # run each scenario once before measuring to catch errors
  percentiles: [50, 99],  # which percentiles to compute (default)
  max_sample_size: 100_000,  # cap samples to avoid Benchee memory bloat (default: 1_000_000)
  title: "ex_h3o vs erlang-h3"
)
```

## Input Configuration

Inputs create one scenario per function × input combination. Use a list of tuples (not a map) to control ordering in output:

```elixir
inputs: [
  {"k=1 (7 cells)", 1},
  {"k=5 (91 cells)", 5},
  {"k=10 (331 cells)", 10},
  {"k=20 (1261 cells)", 20}
]

# Each benchmark function receives the input as its argument:
%{
  "ex_h3o" => fn k -> ExH3o.k_ring(cell, k) end,
  "erlang-h3" => fn k -> :h3.k_ring(cell, k) end
}
```

## Formatters

### Console (default, always include)

```elixir
Benchee.Formatters.Console
```

Shows IPS, average, deviation, median, p99, comparison table.

### HTML (for publishable results)

```elixir
# mix.exs dep: {:benchee_html, "~> 1.0", only: :dev}

{Benchee.Formatters.HTML, file: "bench/output/results.html", auto_open: false}
```

Generates interactive plotly.js charts: IPS bar chart, run time boxplot, histogram. One HTML file per input.

### Multiple formatters

```elixir
formatters: [
  Benchee.Formatters.Console,
  {Benchee.Formatters.HTML, file: "bench/output/results.html", auto_open: false}
]
```

## Hooks

Hooks run setup/teardown code that is NOT included in timing:

```elixir
Benchee.run(%{
  "with_setup" => {
    fn cell -> ExH3o.k_ring(cell, 10) end,
    before_each: fn _input ->
      # Create a fresh cell for each measurement — not timed
      {:ok, cell} = ExH3o.from_geo({48.8566, 2.3522}, 5)
      cell
    end
  }
})
```

Hook execution order (global wraps local):
`global_before_scenario → local_before_scenario → global_before_each → local_before_each → **function** → local_after_each → global_after_each → local_after_scenario → global_after_scenario`

## Parallel Execution

`parallel: N` spawns N processes running the same benchmark simultaneously. This is for **stress testing**, not faster benchmarks:

- Higher parallelism increases standard deviation due to OS scheduling and CPU contention
- Results represent throughput under contention, not isolated performance
- Useful for validating NIF behavior under concurrent load

```elixir
# Stress test: 8 concurrent callers
Benchee.run(%{...}, parallel: System.schedulers_online(), time: 10)
```

## NIF-Specific Patterns

### Pattern 1: A/B Comparison (ex_h3o vs erlang-h3)

```elixir
cell = 0x8928308280fffff  # known valid H3 cell

Benchee.run(
  %{
    "ex_h3o.k_ring" => fn k -> ExH3o.k_ring(cell, k) end,
    "erlang-h3.k_ring" => fn k -> :h3.k_ring(cell, k) end
  },
  inputs: [
    {"k=1", 1},
    {"k=5", 5},
    {"k=10", 10}
  ],
  warmup: 3,
  time: 10,
  memory_time: 2,
  pre_check: true,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/k_ring.html", auto_open: false}
  ]
)
```

### Pattern 2: Scaling Behavior

Test how performance changes with input size:

```elixir
Benchee.run(
  %{
    "ex_h3o.children" => fn {cell, res} -> ExH3o.children(cell, res) end,
    "erlang-h3.children" => fn {cell, res} -> :h3.children(cell, res) end
  },
  inputs: [
    {"1 level (7 cells)", {cell, cell_res + 1}},
    {"2 levels (49 cells)", {cell, cell_res + 2}},
    {"3 levels (343 cells)", {cell, cell_res + 3}}
  ],
  warmup: 3,
  time: 10,
  memory_time: 2
)
```

### Pattern 3: Single-Cell Operations (Fast NIFs)

For very fast NIFs (< 1µs), be aware:

- Benchee automatically loops fast functions, adding overhead to measurements
- On macOS, clock resolution is ~1µs (vs ~1ns on Linux) — sub-microsecond operations may show identical times
- Benchee itself can consume GBs of memory accumulating millions of samples — set `max_sample_size`

```elixir
Benchee.run(
  %{
    "ex_h3o.is_valid" => fn cell -> ExH3o.is_valid(cell) end,
    "erlang-h3.is_valid" => fn cell -> :h3.is_valid(cell) end
  },
  inputs: [
    {"valid cell", 0x8928308280fffff},
    {"invalid cell", 0}
  ],
  warmup: 2,
  time: 5,
  max_sample_size: 100_000  # prevent Benchee memory bloat on fast functions
)
```

### Pattern 4: Ensure Optimized Compilation

NIF benchmarks must use release-mode Rust compilation. During development, Rustler compiles in debug mode by default, giving misleading results.

```elixir
# In native module:
use Rustler,
  otp_app: :ex_h3o,
  crate: "ex_h3o_nif",
  mode: :release  # ensure optimized native code
```

Or set via environment: `RUSTLER_NIF_MODE=release mix run bench/k_ring.exs`

## Benchmark Suite Organization

```
bench/
  single_cell.exs      # from_geo, to_geo, is_valid, resolution — fast operations
  collections.exs      # k_ring, children, compact — scaling with input size
  polyfill.exs          # polyfill at various resolutions — heavy workload
  concurrent.exs        # parallel: N stress test via Benchee
  output/               # generated HTML reports (gitignored)
```

Run individually: `mix run bench/collections.exs`

## What Memory Numbers Mean for NIFs

When `memory_time` is enabled, Benchee reports memory allocated on the **BEAM process heap** during each call. For NIF functions:

- **Packed binary return** (ex_h3o pattern): Memory shows the refc binary reference overhead (8 words / 64 bytes on OTP 27+) plus the Elixir-side list construction when the binary is unpacked. The actual binary data is off-heap and invisible.
- **BEAM list return** (erlang-h3 pattern): Memory shows the full cons-cell list + integer terms allocated on the process heap. This is the actual allocation that causes GC pressure.

The memory numbers are useful for comparing the BEAM-side allocation cost between implementations, even though NIF-internal memory is not tracked. A packed binary approach should show dramatically lower BEAM memory per call than a list-returning approach.

## Common Mistakes

1. **Benchmarking debug-mode NIFs** — Rust debug builds are 10-100x slower than release. Always verify compilation mode.
2. **Using `reduction_time` for NIFs** — explicitly documented as inaccurate for NIFs and BIFs. Don't include it.
3. **Treating `parallel` as a speedup** — it's for stress testing, not faster benchmarks. It increases variance and measures contention behavior.
4. **Interpreting memory as total allocation** — Benchee memory is BEAM-side only. For total NIF memory impact, use OS-level tools or `:erlang.memory/0` snapshots.
5. **Forgetting `pre_check: true`** — without it, a broken benchmark function silently produces zero measurements. Pre-check runs each scenario once to catch errors early.
6. **Not setting `max_sample_size` for fast NIFs** — default is 1,000,000 samples. Very fast NIFs can cause Benchee itself to consume multiple GB of memory accumulating samples.
