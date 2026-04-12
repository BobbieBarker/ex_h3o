# Rustler Reference

Rustler v0.37+ reference for writing NIFs in ex_h3o. Read `docs/nif-conventions.md` first for boundary design principles — this doc covers the Rustler API itself.

## Project Setup

### mix.exs

```elixir
{:rustler, "~> 0.37", runtime: false}
```

For precompiled distribution (so users don't need Rust installed):
```elixir
{:rustler_precompiled, "~> 0.9"}
```

Run `mix rustler.new` to scaffold the native crate.

### Directory Layout

```
ex_h3o/
  lib/
    ex_h3o/native.ex         # Elixir module with `use Rustler`
  native/
    ex_h3o_nif/               # Rust crate
      Cargo.toml
      src/
        lib.rs                # #[rustler::nif] functions + rustler::init!()
  mix.exs
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
crate-type = ["cdylib"]       # Required: produces shared library for BEAM

[dependencies]
rustler = "0.37"
h3o = { version = "0.9", features = ["geo"] }
```

### Elixir NIF Module

```elixir
defmodule ExH3o.Native do
  use Rustler,
    otp_app: :ex_h3o,
    crate: "ex_h3o_nif"

  # Stubs replaced at load time by NIF implementations.
  # Each stub must match the Rust function's name and arity.
  def from_geo(_lat, _lng, _resolution), do: :erlang.nif_error(:nif_not_loaded)
end
```

Key `use Rustler` options:
- `:otp_app` (required) — OTP app containing the compiled artifact
- `:crate` — Rust crate name if different from otp_app
- `:mode` — `:release` (default) or `:debug`
- `:skip_compilation?` — skip Rust compilation (for precompiled NIFs)

### Rust Init

```rust
// src/lib.rs
rustler::init!("Elixir.ExH3o.Native");
```

Functions annotated with `#[rustler::nif]` are auto-discovered — no need to list them.

## NIF Function Declaration

### Basic

```rust
#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}
```

The `#[rustler::nif]` attribute:
- Auto-decodes arguments from BEAM terms (via `Decoder` trait)
- Auto-encodes return value (via `Encoder` trait)
- Wraps in `catch_unwind` to prevent panics from crashing the BEAM
- Supported attributes: `schedule = "DirtyCpu" | "DirtyIo" | "Normal"`, `name = "custom_name"`

### Accessing the Environment

If the first parameter is `Env<'a>`, it is NOT counted toward NIF arity:

```rust
#[rustler::nif]
fn notify(env: Env, pid: LocalPid, msg: String) -> Atom {
    env.send(&pid, msg.encode(env)).unwrap();
    atoms::ok()
}
```

### Scheduler Selection

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn heavy_work(data: Vec<f64>) -> f64 { /* ... */ }

#[rustler::nif(schedule = "DirtyIo")]
fn read_file(path: String) -> Result<Vec<u8>, String> { /* ... */ }
```

### Custom NIF Name

```rust
#[rustler::nif(name = "valid?")]
fn is_valid(cell: u64) -> bool { /* ... */ }
```

Elixir stub must use the custom name: `def valid?(_cell), do: :erlang.nif_error(:nif_not_loaded)`

## Return Types

### Direct Return

Any type implementing `Encoder`:

```rust
#[rustler::nif]
fn get_name() -> String { "hello".to_string() }
```

### Result → ok/error tuples

`Result<T, E>` where both implement `Encoder` auto-encodes to `{:ok, value}` / `{:error, reason}`:

```rust
#[rustler::nif]
fn divide(a: f64, b: f64) -> Result<f64, String> {
    if b == 0.0 { Err("division by zero".to_string()) } else { Ok(a / b) }
}
// Returns {:ok, 2.5} or {:error, "division by zero"}
```

### NifResult (raising exceptions)

`NifResult<T>` is `Result<T, rustler::Error>`:

```rust
#[rustler::nif]
fn parse(input: String) -> NifResult<i64> {
    input.parse::<i64>().map_err(|_| Error::BadArg)
}
```

Error variants:
- `Error::BadArg` — raises `badarg`
- `Error::Atom("reason")` — returns the atom directly
- `Error::Term(Box::new(value))` — returns `{:error, value}`
- `Error::RaiseAtom("reason")` — raises exception with atom
- `Error::RaiseTerm(Box::new(value))` — raises exception with term

### Option → value or nil

```rust
#[rustler::nif]
fn parent(cell: u64, res: u8) -> Option<u64> {
    // Returns the value or :nil
}
```

## Type Mappings

### Primitives

| Rust | BEAM |
|---|---|
| `i8`, `i16`, `i32`, `i64`, `isize` | integer |
| `u8`, `u16`, `u32`, `u64`, `usize` | non-negative integer |
| `f32`, `f64` | float (f64 decodes from both float and integer) |
| `bool` | `true` / `false` atoms |

### Strings and Binaries

| Rust | BEAM |
|---|---|
| `String`, `&str` | binary (UTF-8) |
| `Binary<'a>` | binary (immutable reference, lifetime tied to Env) |
| `OwnedBinary` | binary (owned, mutable, Send + Sync) |
| `NewBinary<'a>` | binary (env-allocated, mutable until frozen) |

### Collections

| Rust | BEAM |
|---|---|
| `Vec<T>` | list |
| `HashMap<K, V>` | map |
| `(A, B, ...)` | tuple (up to 7 elements) |
| `ListIterator<'a>` | list (lazy iteration, no conversion) |
| `MapIterator<'a>` | map (lazy iteration) |

### Special Types

| Rust | BEAM |
|---|---|
| `Atom` | atom |
| `Term<'a>` | any term (pass-through) |
| `LocalPid` | pid |
| `ResourceArc<T>` | opaque resource reference |
| `Option<T>` | value or `:nil` |
| `Result<T, E>` | `{:ok, T}` or `{:error, E}` |

## Custom Atoms

```rust
mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_index,
        invalid_coordinates,
    }
}
// Usage: atoms::ok(), atoms::invalid_index()
```

Atoms are lazily initialized on first use, then cached. They are `Send + Sync`.

## Derive Macros for Structs/Enums

### NifStruct — maps to/from Elixir struct

```rust
#[derive(NifStruct)]
#[module = "ExH3o.LatLng"]
pub struct LatLng { pub lat: f64, pub lng: f64 }
```
Elixir: `%ExH3o.LatLng{lat: 1.0, lng: 2.0}`

### NifMap — maps to/from plain map

```rust
#[derive(NifMap)]
pub struct Config { pub width: u32, pub height: u32 }
```
Elixir: `%{width: 100, height: 200}`

### NifTuple — maps to/from tuple

```rust
#[derive(NifTuple)]
pub struct Pair { pub first: f64, pub second: f64 }
```
Elixir: `{1.0, 2.0}`

### NifUnitEnum — variants to/from atoms

```rust
#[derive(NifUnitEnum)]
pub enum ContainmentMode { ContainsCentroid, IntersectsBoundary }
```
Elixir: `:contains_centroid`, `:intersects_boundary` (auto snake_cased)

### NifTaggedEnum — variants to atoms or `{:tag, ...}` tuples

```rust
#[derive(NifTaggedEnum)]
pub enum IndexResult {
    Valid,                    // atom :valid
    Invalid(String),          // {:invalid, "reason"}
}
```

## Resource Objects

Wrap a Rust struct as an opaque BEAM term. The BEAM GC handles the lifetime.

### Define and Register

```rust
use rustler::{Resource, ResourceArc};

pub struct ComputeResult {
    cells: Vec<u64>,
}

#[rustler::resource_impl]
impl Resource for ComputeResult {}
```

`Resource` trait requires `Sized + Send + Sync + 'static`.

### Use in NIFs

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn compute(/* args */) -> ResourceArc<ComputeResult> {
    let cells = /* expensive work */;
    ResourceArc::new(ComputeResult { cells })
}

#[rustler::nif]
fn result_count(resource: ResourceArc<ComputeResult>) -> usize {
    resource.cells.len()
}
```

`ResourceArc<T>`:
- Behaves like `Arc` — reference-counted, thread-safe
- `Deref` to `&T` — access fields directly via `resource.field`
- Data is immutable by default; use `Mutex`/`RwLock` for interior mutability
- Dropped when refcount reaches zero (both Rust and BEAM refs count)

### Resource Binaries (zero-copy)

```rust
#[rustler::nif]
fn get_bytes(env: Env, resource: ResourceArc<ComputeResult>) -> Binary {
    resource.make_binary(env, |state| {
        // Return a byte slice with lifetime tied to the resource
        unsafe { std::slice::from_raw_parts(state.cells.as_ptr() as *const u8, state.cells.len() * 8) }
    })
}
```

## Binary Handling

### Reading binary arguments

```rust
#[rustler::nif]
fn process(bin: Binary) -> usize {
    bin.as_slice().len()
}
```

### Creating binaries

**`NewBinary`** — for small binaries returned immediately. Can be heap-allocated for small sizes (more efficient):

```rust
#[rustler::nif]
fn make_small(env: Env) -> Binary {
    let mut new = NewBinary::new(env, 4);
    new.as_mut_slice().copy_from_slice(&[1, 2, 3, 4]);
    new.into()
}
```

**`OwnedBinary`** — for larger binaries or thread-safe contexts. Always allocated as refc binary:

```rust
#[rustler::nif]
fn pack_cells(cells: Vec<u64>) -> NifResult<OwnedBinary> {
    let mut owned = OwnedBinary::new(cells.len() * 8)
        .ok_or(Error::Term(Box::new("alloc failed")))?;
    for (i, cell) in cells.iter().enumerate() {
        owned.as_mut_slice()[i*8..(i+1)*8].copy_from_slice(&cell.to_native_bytes());
    }
    Ok(owned)
}
```

**Decision rule:**
- Small binary returned immediately → `NewBinary`
- Large binary or built incrementally → `OwnedBinary`
- Zero-copy view into a resource → `ResourceArc::make_binary`

## Threaded Async NIFs

Spawn a Rust thread, send result to calling process. NIF returns immediately.

```rust
use rustler::thread;

#[rustler::nif]
fn compute_async(env: Env, input: u64) -> Atom {
    thread::spawn::<thread::ThreadSpawner, _>(env, move |thread_env| {
        let result = expensive_work(input);
        result.encode(thread_env)
    });
    atoms::ok()
}
```

How it works:
1. Captures calling process PID
2. Spawns OS thread
3. Creates `OwnedEnv` on the new thread
4. Runs closure, catches panics
5. Sends result as message to calling PID

Elixir side receives the result:
```elixir
def compute_async(input) do
  :ok = ExH3o.Native.compute_async(input)
  receive do
    result -> {:ok, result}
  after
    5_000 -> {:error, :timeout}
  end
end
```

## Timeslice Consumption

For NIFs iterating over data that want to cooperate with the scheduler:

```rust
use rustler::schedule::consume_timeslice;

#[rustler::nif]
fn process_items(env: Env, items: Vec<i64>) -> i64 {
    let mut sum = 0;
    for (i, item) in items.iter().enumerate() {
        sum += item;
        if i % 100 == 0 && consume_timeslice(env, 1) {
            // Timeslice exhausted
            break;
        }
    }
    sum
}
```

Note: Rustler does NOT provide built-in yielding/rescheduling NIF support (`enif_schedule_nif` wrapper). For long work, use dirty schedulers or threaded NIFs.

## Precompiled NIFs (RustlerPrecompiled)

For hex.pm distribution so users don't need a Rust toolchain:

```elixir
defmodule ExH3o.Native do
  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ex_h3o,
    crate: "ex_h3o_nif",
    base_url: "https://github.com/bobbiebarker/ex_h3o/releases/download/v#{version}",
    version: version,
    force_build: System.get_env("EX_H3O_BUILD") in ["1", "true"]

  def from_geo(_lat, _lng, _resolution), do: :erlang.nif_error(:nif_not_loaded)
end
```

Checksum workflow:
1. CI builds artifacts for all targets, uploads to GitHub releases
2. Run `mix rustler_precompiled.download ExH3o.Native --all --print` to generate checksums
3. Include checksum file in hex package
