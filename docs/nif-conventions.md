# NIF Design Conventions

This document is the authoritative reference for NIF boundary design in ex_h3o. Every agent implementing NIF code MUST read this before writing any code.

## The Core Principle

**Never combine expensive computation with expensive term construction in a single NIF call.**

The erlang-h3 library we're replacing is reported to have this problem: H3 computation followed by materialization of large BEAM term trees (lists of strings, tuples) inside dirty CPU NIFs. This causes GC pressure attributed to the dirty scheduler instead of the calling process. Verify this against the actual erlang-h3 source before citing it as confirmed fact.

ex_h3o must not repeat that shape regardless.

## BEAM Scheduler Architecture

- **Normal schedulers** (N = CPU cores): Run Erlang processes cooperatively. NIFs must complete in <1ms.
- **Dirty CPU schedulers** (N = CPU cores): For CPU-bound NIFs >1ms. No GC, no preemption during execution.
- **Dirty IO schedulers** (10 threads): For I/O-bound blocking work.

When a dirty NIF constructs terms, those terms are allocated on the calling process's heap, but GC cannot run until the NIF returns. Large allocations in a dirty NIF bloat the process heap with no GC relief, followed by a massive GC sweep when the NIF returns.

## Return Value Patterns

These are the available patterns for returning data from NIFs, ordered from least to most GC pressure. The right choice depends on the specific function — profile and measure before committing to a pattern.

### 1. Direct Return (small results)

For single values, small tuples, booleans, integers, floats. Trivial term construction, runs on normal scheduler.

```rust
#[rustler::nif]
fn resolution(cell: u64) -> NifResult<u8> {
    let cell = CellIndex::try_from(cell).map_err(|_| Error::BadArg)?;
    Ok(cell.resolution() as u8)
}
```

### 2. Packed Binary (collections)

Pack results into a single binary with a defined wire format. One refc binary = ~40 bytes GC-visible heap regardless of data size. Decode on the Elixir side with binary pattern matching.

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn k_ring_packed(cell: u64, k: u32) -> NifResult<OwnedBinary> {
    let cell = CellIndex::try_from(cell).map_err(|_| Error::BadArg)?;
    let cells: Vec<CellIndex> = cell.grid_disk(k);

    // 8 bytes per cell (u64)
    let mut binary = OwnedBinary::new(cells.len() * 8).unwrap();
    let buf = binary.as_mut_slice();
    for (i, c) in cells.iter().enumerate() {
        buf[i*8..(i+1)*8].copy_from_slice(&u64::from(*c).to_native_bytes());
    }
    Ok(binary)
}
```

Elixir side:
```elixir
def k_ring(cell, k) do
  packed = ExH3o.Native.k_ring_packed(cell, k)
  for <<index::native-unsigned-64 <- packed>>, do: index
end
```

### 3. Resource + Accessor (large or lazily consumed results)

Store computation results in a `ResourceArc` (opaque reference, ~1 word on process heap), provide accessor NIFs on normal schedulers to pull data out in chunks.

```rust
struct ComputeResult {
    cells: Vec<CellIndex>,
}

#[rustler::resource_impl]
impl Resource for ComputeResult {}

#[rustler::nif(schedule = "DirtyCpu")]
fn compute(/* args */) -> ResourceArc<ComputeResult> {
    let cells = /* expensive work */;
    ResourceArc::new(ComputeResult { cells })
}

#[rustler::nif]  // Normal scheduler, returns batch as packed binary
fn get_batch(resource: ResourceArc<ComputeResult>, offset: usize, count: usize) -> OwnedBinary {
    let end = (offset + count).min(resource.cells.len());
    let slice = &resource.cells[offset..end];
    // pack into binary...
}
```

### 4. Threaded Async (fire-and-forget with result delivery)

Spawn a Rust thread, send the result to the calling process as a message. The NIF returns immediately.

```rust
#[rustler::nif]
fn compute_async(env: Env, /* args */) -> Atom {
    let pid = env.pid();
    thread::spawn::<thread::ThreadSpawner, _>(env, move |thread_env| {
        let result = expensive_work(/* args */);
        encode_packed_result(thread_env, &result)
    });
    atoms::ok()
}
```

Use sparingly — only when the caller genuinely wants async semantics.

## Scheduler Guidelines

- **Normal scheduler**: For operations that are clearly O(1) or bounded small (bit extraction, single coordinate conversion, validation, string parse). Must complete in <1ms.
- **Dirty CPU**: For operations whose cost depends on input size and may exceed 1ms (traversal with large k, children at distant resolution, compaction over large sets, polygon coverage).
- **When in doubt**: Profile first. Don't prematurely mark things as dirty — dirty schedulers are a limited pool.

For functions whose cost varies by input (e.g., k_ring with small vs large k), consider either providing two variants or using a runtime threshold to select the scheduler. The specific thresholds should be determined by benchmarking, not guessed.

## h3o Rust API Reference

### Types

| h3o Type | Elixir Representation | NIF Boundary |
|---|---|---|
| `CellIndex` | `non_neg_integer()` (u64) | `u64` via `TryFrom<u64>` |
| `LatLng` | `{float(), float()}` | Two `f64` args |
| `Resolution` | `0..15` integer | `u8` via `Resolution::try_from()` |
| `DirectedEdgeIndex` | `non_neg_integer()` (u64) | `u64` via `TryFrom<u64>` |
| `Boundary` | `[{float(), float()}]` | Pack as binary or small list (typically 5-6 vertices) |

h3o uses strong typing (newtypes over u64). Validation happens at the Rust boundary via `TryFrom` — return `{:error, :invalid_index}` on failure.

### Key API Differences from C H3

- `Resolution` is an enum, not a bare integer — convert from Elixir integer via `Resolution::try_from(n as u8)`
- `LatLng::new()` validates coordinates (rejects NaN/Infinity) — the C API silently accepted garbage
- `compact()` mutates in place (`&mut Vec<CellIndex>`) — collect Elixir list into Vec, compact, return
- Iterators everywhere (`children()`, `grid_disk()`, `uncompact()`) — collect into Vec in the NIF
- Polyfill uses a builder pattern with containment modes — expose mode as an optional parameter
- `is_neighbor_with()` errors on resolution mismatch — handle gracefully
- `geo` feature required for polygon operations (pulls in the `geo` crate)

### Error Mapping

| h3o Error | Elixir Return |
|---|---|
| `InvalidCellIndex` | `{:error, :invalid_index}` |
| `InvalidLatLng` | `{:error, :invalid_coordinates}` |
| `ResolutionMismatch` | `{:error, :resolution_mismatch}` |
| `CompactionError` | `{:error, :compaction_failed}` |
| `LocalIjError` | `{:error, :local_ij_error}` |
| `DissolutionError` | `{:error, :dissolution_failed}` |

## Rustler Project Structure

```
native/
  ex_h3o_nif/
    Cargo.toml          # crate-type = ["cdylib"], deps: rustler, h3o
    src/
      lib.rs            # rustler::init!, NIF function definitions
      types.rs          # NifStruct/NifMap derives, custom encoders
      atoms.rs          # Custom atom definitions (ok, error, etc.)
```

```elixir
# lib/ex_h3o/native.ex
defmodule ExH3o.Native do
  use Rustler,
    otp_app: :ex_h3o,
    crate: "ex_h3o_nif"

  def from_geo(_lat, _lng, _resolution), do: :erlang.nif_error(:nif_not_loaded)
  # ... stubs for all NIF functions
end
```

### Cargo.toml

```toml
[package]
name = "ex_h3o_nif"
version = "0.1.0"
edition = "2021"

[lib]
name = "ex_h3o_nif"
path = "src/lib.rs"
crate-type = ["cdylib"]

[dependencies]
rustler = "0.37"
h3o = { version = "0.9", features = ["geo"] }
```

The `geo` feature is required for polyfill and set_to_multi_polygon operations.

## Anti-Patterns (DO NOT)

1. **DO NOT build large lists of small terms in a dirty NIF.** Use packed binaries or resources instead.

2. **DO NOT format strings inside a NIF.** No `format!()` for building Elixir-visible strings. Return raw data, format in Elixir.

3. **DO NOT combine long computation + large term construction.** Split into compute (returns resource or binary) + materialize (runs on normal scheduler).

4. **DO NOT return charlists.** Always return binaries (Elixir strings), never Erlang charlists.

5. **DO NOT use `Vec<T>` return types for large collections.** Rustler auto-encodes `Vec<T>` as a BEAM list, hitting anti-pattern #1. Use `OwnedBinary` instead.

6. **DO NOT ignore the 1ms rule.** Normal scheduler NIFs must complete in <1ms. If there's any doubt, profile it.
