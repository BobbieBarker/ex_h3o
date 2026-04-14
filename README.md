# ExH3o

Elixir bindings for [h3o](https://github.com/HydroniumLabs/h3o), a
Rust implementation of Uber's [H3](https://h3geo.org/docs/) geospatial
indexing system.

H3 maps geographic coordinates onto a hierarchical grid of hexagonal
cells at 16 resolutions. It's widely used for spatial indexing,
aggregation, and analysis of location data.

## Features

- Full coverage of common H3 v4 operations: cell indexing, geo
  conversion, k-rings, children/parent hierarchy, neighbors, edges,
  polygon fill, and compaction.
- Native-speed lookups via a thin C NIF that links against a Rust
  staticlib wrapping `h3o`. No Rust toolchain is required at runtime,
  only at build time.
- Bare return values, `ArgumentError` on invalid input. Matches the
  convention used by the reference [erlang-h3](https://hex.pm/packages/h3)
  library, so code that mixes the two doesn't change shape.
- Graceful shutdown for in-flight dirty NIFs via
  `ERL_NIF_OPT_DELAY_HALT`.

## Performance vs erlang-h3

[erlang-h3](https://hex.pm/packages/h3) is the established H3 binding
for the Elixir ecosystem. ExH3o is a drop-in alternative that runs
faster than erlang-h3 on most operations in the H3 v4 API surface.

Benchmarks below were measured on an Apple M1 Pro running Elixir
1.19.5 / OTP 28, head-to-head under Benchee with 5 seconds of
measurement per scenario. Times are per-call averages. The `Speedup`
column is the ratio `erlang-h3 / ex_h3o`; values greater than 1.0
mean ex_h3o is faster and values less than 1.0 mean ex_h3o is
slower. See [Reproducing](#reproducing) below to run the same
suite on your own hardware.

### `polyfill/2`

| Polygon          | Resolution | erlang-h3 | ex_h3o   | Speedup |
|------------------|-----------:|----------:|---------:|--------:|
| ~1 SF block      |          7 |  31.03 µs |  6.34 µs | 4.89×   |
| ~1 SF block      |          9 |  53.31 µs | 18.68 µs | 2.85×   |
| ~1 SF block      |         11 | 362.45 µs | 198.0 µs | 1.83×   |
| ~1 km² urban     |          7 |  21.30 µs |  8.24 µs | 2.59×   |
| ~1 km² urban     |          9 |  97.91 µs | 69.41 µs | 1.41×   |
| ~1 km² urban     |         11 |   1.92 ms |  0.87 ms | 2.21×   |
| ~100 km² region  |          5 |  53.91 µs | 23.41 µs | 2.30×   |
| ~100 km² region  |          7 | 473.80 µs | 273.6 µs | 1.73×   |
| ~100 km² region  |          8 |   2.54 ms |  1.24 ms | 2.05×   |

### Single-cell operations

| Operation              | erlang-h3 | ex_h3o    | Speedup    |
|------------------------|----------:|----------:|-----------:|
| `is_valid/1` (valid)   |  46.95 ns |  15.64 ns | 3.00×      |
| `get_base_cell/1`      |  52.47 ns |  20.81 ns | 2.52×      |
| `get_resolution/1`     |  50.59 ns |  21.08 ns | 2.40×      |
| `from_string/1`        | 139.06 ns |  70.02 ns | 1.99×      |
| `is_pentagon/1`        |  30.47 ns |  20.75 ns | 1.47×      |
| `to_geo/1`             |    284 ns |    248 ns | 1.14×      |
| `from_geo/2`           |    320 ns |    325 ns | 0.98×      |
| `to_string/1`          |    119 ns |    140 ns | 0.85×      |

### Grid and hierarchy

| Operation              | Input              | erlang-h3 | ex_h3o    | Speedup |
|------------------------|--------------------|----------:|----------:|--------:|
| `k_ring/2`             | k=1 (7 cells)      |    230 ns |    139 ns | 1.66×   |
| `k_ring/2`             | k=5 (91 cells)     |   1.82 µs |   1.40 µs | 1.30×   |
| `k_ring/2`             | k=10 (331 cells)   |   6.30 µs |   5.46 µs | 1.15×   |
| `k_ring/2`             | k=20 (1,261 cells) |  27.76 µs |  23.92 µs | 1.16×   |
| `k_ring/2`             | k=50 (7,651 cells) | 162.37 µs | 163.19 µs | 0.99×   |
| `k_ring_distances/2`   | k=1                |    309 ns |    173 ns | 1.79×   |
| `k_ring_distances/2`   | k=5                |   2.08 µs |   1.89 µs | 1.10×   |
| `k_ring_distances/2`   | k=10               |   7.66 µs |   7.26 µs | 1.06×   |
| `children/2`           | +1 level (7)       |    180 ns |    134 ns | 1.34×   |
| `children/2`           | +2 levels (49)     |    449 ns |    415 ns | 1.08×   |
| `children/2`           | +3 levels (343)    |   2.72 µs |   2.74 µs | 0.99×   |

### Set operations

`compact/1` and `uncompact/2` are slower than erlang-h3 on small
inputs (roughly 0.5× and 0.75× speedup in the benchmarks below).
If your workload leans heavily on these operations, benchmark both
libraries against representative inputs before choosing.

### Reproducing

```bash
mix run bench/single_cell.exs
mix run bench/collections.exs
mix run bench/polyfill.exs
```

Each script prints a head-to-head comparison table for one
category of operations.

## Installation

Add `ex_h3o` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:ex_h3o, "~> 0.1.0"}
  ]
end
```

Then run `mix deps.get` and `mix compile`. The compile step builds
the Rust staticlib via `cargo` and links it into a C shared object
at `priv/ex_h3o_nif.so`.

### Build requirements

- Elixir 1.18+ / OTP 26+ (OTP 28 recommended)
- A C compiler (`cc`) available on `PATH`
- A Rust toolchain (`cargo`) available on `PATH`
- macOS and Linux are supported. Windows is not.

## Usage

```elixir
# Convert a {lat, lng} coordinate to an H3 cell at a given resolution
cell = ExH3o.from_geo({37.7749, -122.4194}, 9)
# => 617700169958686719

# Round-trip back to coordinates
ExH3o.to_geo(cell)
# => {37.77490199, -122.41942334}

# Grid queries
ExH3o.k_ring(cell, 2)           # cells within distance 2
ExH3o.children(cell, 11)        # child cells at a finer resolution
ExH3o.parent(cell, 7)           # parent cell at a coarser resolution
ExH3o.is_pentagon(cell)         # pentagon check
ExH3o.grid_distance(cell_a, cell_b)

# Polygon fill
polygon = [
  {37.770, -122.420},
  {37.770, -122.410},
  {37.780, -122.410},
  {37.780, -122.420},
  {37.770, -122.420}
]
ExH3o.polyfill(polygon, 9)
```

Invalid input raises rather than returning an error tuple:

```elixir
ExH3o.from_geo({900.0, 0.0}, 9)
# ** (ArgumentError) argument error

ExH3o.get_resolution(0)
# ** (ArgumentError) argument error
```

If you'd rather get `{:ok, _} | {:error, _}` back, wrap the call
site in `try/rescue`.

See the module docs for the complete API:
[https://hexdocs.pm/ex_h3o](https://hexdocs.pm/ex_h3o).

## Development

```bash
# Fetch deps
mix deps.get

# Compile (builds the Rust staticlib + C NIF)
mix compile

# Run the test suite
mix test

# Formatter / linter / type checker
mix format --check-formatted
mix credo --strict
mix dialyzer
```

### Benchmarks

Comparative benchmarks against erlang-h3 live under `bench/`:

```bash
mix run bench/single_cell.exs     # scalar per-call ops
mix run bench/collections.exs     # k_ring, children, compact, uncompact
mix run bench/polyfill.exs        # polygon fill across sizes
mix run bench/gc_deep_dive.exs    # side-by-side GC pressure measurement
mix run bench/stress.exs          # concurrent-load stress harness
```

## Contributing

Contributions are welcome. Please open an issue before starting any
sizable change so we can discuss direction.

Before submitting a PR:

1. Add or update tests for any behaviour change.
2. Run `mix format`, `mix credo --strict`, and `mix test` locally.
3. Keep commits focused and write a clear commit message.

Bug reports with a minimal reproduction are appreciated.

## License

Released under the MIT License. See [LICENSE](LICENSE) for details.
