# ex_h3o Agent Guide

`ex_h3o` is an Elixir library that exposes H3 geospatial operations from the
Rust `h3o` crate through a C NIF. It is a library/Hex package, not an OTP
application with supervised native state, a database, or a web layer.

Read `README.md`, the relevant module docs, and the tests before changing a
public operation. Keep this guide aligned with the implementation when the
native boundary or CI workflow changes.

## Public API contract

- `ExH3o` is the public API. Keep public specs, module documentation, doctests,
  README examples, and tests synchronized.
- Return shapes are intentionally bare values: cells, booleans, coordinates,
  lists, and other direct results. Do not introduce `{:ok, value}` /
  `{:error, reason}` wrappers or bang-function variants as a routine cleanup.
  This convention is compatibility with `erlang-h3`.
- Native validation failures return `enif_make_badarg` from C and surface as
  `ArgumentError`. `is_valid/1` is the deliberate predicate exception: for
  non-negative integers it returns `true` or `false`.
- Elixir guard failures can surface as `FunctionClauseError`; preserve the
  documented distinction from native `ArgumentError` unless a task explicitly
  changes the public contract.
- Maintain `{latitude, longitude}` at the Elixir API. Rust `geo-types` uses
  `{x, y}`, so polygon coordinates must cross the Rust boundary as
  `x = longitude`, `y = latitude`.

## Implementation map

- `lib/ex_h3o.ex` owns the public API, pure-Elixir calculations, guards, and
  input packing. Collection cells are packed as native-endian `u64` values;
  polygon vertices are packed as native-endian `f64` latitude/longitude pairs
  before dirty-NIF dispatch.
- `lib/ex_h3o/native.ex` is internal. Its `@on_load` callback loads
  `priv/ex_h3o_nif`, and every fallback stub must call
  `:erlang.nif_error(:nif_not_loaded)`.
- `native/ex_h3o_nif/c_src/ex_h3o_nif.c` is the BEAM boundary. It validates and
  decodes Erlang terms, registers scheduler classes, calls the Rust ABI, and
  constructs Erlang results.
- `native/ex_h3o_nif/src/lib.rs` owns H3 computation through `h3o`. It must not
  include `erl_nif.h`, manipulate BEAM terms, or depend on an `ErlNifEnv`.
- `native/ex_h3o_nif/Makefile` builds the Rust crate as a static library and
  links it with the C source into the single loadable NIF. `elixir_make` drives
  this build from `mix.exs`; release consumers may instead receive a
  `cc_precompiler` artifact.

An operation that crosses the native boundary normally requires coordinated
changes to the public wrapper and spec, `ExH3o.Native` stub, C declaration and
wrapper, Rust `extern "C"` export, `nif_funcs` registration, and tests.

## NIF safety invariants

- A native crash takes down the BEAM. Validate every term, length, range, and
  pointer before use; never rely on Rust to make an invalid C read safe.
- No Rust panic may unwind across the C ABI. Keep fallible exports behind the
  existing `catch_unwind` boundary and translate failures to the established
  nonzero status code. C maps that status to `enif_make_badarg`.
- Variable-length Rust results transfer through `ExH3oBuf`. Rust allocates the
  boxed byte buffer, C copies it into BEAM terms, and C must call
  `ex_h3o_buf_free` exactly once on every owned result path. Keep the free
  function's pointer/length clearing behavior.
- Keep packed-binary/raw-buffer processing across the C/Rust boundary. Build
  BEAM terms in C; do not move per-term decoding or term construction into
  Rust.
- `compact`, `uncompact`, and `polyfill` are registered as
  `ERL_NIF_DIRTY_JOB_CPU_BOUND` because their work is unbounded. Scalar
  operations plus the current `children`, `k_ring`, and `k_ring_distances`
  paths remain normal NIFs based on measured sub-millisecond workloads and
  dirty-dispatch overhead. Change scheduler flags only with representative
  benchmark and stress evidence; normal NIF work must stay below roughly 1 ms.
- Preserve `ERL_NIF_OPT_DELAY_HALT` and its shutdown regression test so
  in-flight dirty work can finish during VM halt on supported OTP releases.
- The NIF is stateless: there are no resource handles, native owners, mutexes,
  or process-bound lifetimes. Do not add global mutable state where a
  per-call value will do.
- Keep unsafe Rust blocks narrow, documented with `SAFETY` reasoning, and
  compatible with `#![deny(unsafe_op_in_unsafe_fn)]`.

## Validation

Install dependencies once with:

```bash
mix deps.get
```

Run the configured full local gate exactly:

```bash
mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=dev mix dialyzer && mix test
```

The current GitHub Actions workflow uses Elixir 1.20.1, OTP 28.2, and stable
Rust. Its test job runs with `MIX_ENV=test`, removes the app's test build before
compilation, runs the same format/Credo/warnings-as-errors checks, and executes
`mix test --cover --export-coverage default`. Its separate Dialyzer job runs
with `MIX_ENV=dev`, removes the app's dev build, and executes `mix dialyzer`.
When diagnosing a CI-only failure, reproduce the environment and command from
the failing job rather than weakening the workflow.

Use the existing test layers:

- `test/ex_h3o_test.exs` for examples, errors, boundary cases, and doctests.
- `test/ex_h3o_property_test.exs` for round trips and H3 invariants.
- `test/ex_h3o_shutdown_test.exs` for delayed-halt behavior in a separate VM.
- `bench/` for scheduler, allocation, throughput, and comparative performance
  questions; benchmarks are evidence, not part of the required CI gate.

Every behavior or native-boundary change needs focused regression coverage.
Before handing work off, review the diff for API-shape drift, missing ABI
counterparts, buffer leaks, scheduler misclassification, coordinate reversal,
and documentation that no longer matches actual exceptions or return values.

## Git

- Name ticket branches `FGE-{number}` and keep one commit per PR.
- Include `Fixes FGE-{number}` in both the commit message and PR body.
- Never force-push `main`.
- Do not modify `.github/workflows/` unless the task is specifically about CI
  configuration.
