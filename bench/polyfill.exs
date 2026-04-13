# Polyfill benchmark — heaviest workload in the library
#
# Run: `mix run bench/polyfill.exs`
#
# Polyfill's cost scales with both polygon area and resolution. At high
# resolutions over large polygons it can produce millions of cells, which
# is the canonical stress case for the packed-binary return type — a list
# approach would GC-poison the BEAM at that volume.
#
# Scenarios cover three polygon sizes × multiple resolutions each.

dylib_path =
  Path.join([
    File.cwd!(),
    "native/ex_h3o_nif/target/release/libex_h3o_nif.dylib"
  ])

unless File.exists?(dylib_path) do
  IO.puts(:stderr, "ERROR: release-mode NIF dylib not found at #{dylib_path}")
  System.halt(1)
end

# Small polygon: ~4 city blocks (SF)
small_polygon = [
  {37.7749, -122.4194},
  {37.7749, -122.4094},
  {37.7849, -122.4094},
  {37.7849, -122.4194},
  {37.7749, -122.4194}
]

# Medium polygon: ~1 km square
medium_polygon = [
  {37.7700, -122.4200},
  {37.7700, -122.4100},
  {37.7800, -122.4100},
  {37.7800, -122.4200},
  {37.7700, -122.4200}
]

# Large polygon: ~100 km square (covers most of the Bay Area)
large_polygon = [
  {37.3000, -122.5000},
  {37.3000, -121.9000},
  {38.0000, -121.9000},
  {38.0000, -122.5000},
  {37.3000, -122.5000}
]

# Sanity check: verify each polygon actually produces cells at the
# resolutions we're about to benchmark. `pre_check: true` will catch this
# too but failing in setup is more informative.
for {name, poly, res} <- [
      {"small@9", small_polygon, 9},
      {"medium@9", medium_polygon, 9},
      {"large@7", large_polygon, 7}
    ] do
  case ExH3o.polyfill(poly, res) do
    {:ok, cells} ->
      IO.puts("  #{name}: #{length(cells)} cells")

    {:error, reason} ->
      IO.puts(:stderr, "polyfill sanity check failed for #{name}: #{inspect(reason)}")
      System.halt(1)
  end
end

# Warm the NIF
_ = ExH3o.polyfill(small_polygon, 7)

IO.puts("""

============================================================
 ex_h3o polyfill benchmark
============================================================
 dylib:    #{dylib_path}
 OTP:      #{System.otp_release()}
 Elixir:   #{System.version()}
 schedulers: #{System.schedulers_online()} online / #{System.schedulers()} total

""")

# --- Small polygon: resolution sweep -------------------------------------
# This exercises the fast case — low cell count, should be sub-ms.

Benchee.run(
  %{
    "polyfill/2 (small polygon)" => fn res -> ExH3o.polyfill(small_polygon, res) end
  },
  inputs: [
    {"res=7", 7},
    {"res=9", 9},
    {"res=11", 11}
  ],
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false],
  title: "polyfill/2 — small polygon (SF ~1 block)"
)

# --- Medium polygon: resolution sweep ------------------------------------

Benchee.run(
  %{
    "polyfill/2 (medium polygon)" => fn res ->
      ExH3o.polyfill(medium_polygon, res)
    end
  },
  inputs: [
    {"res=8", 8},
    {"res=10", 10},
    {"res=12", 12}
  ],
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false],
  title: "polyfill/2 — medium polygon (SF ~1 km\u00B2)"
)

# --- Large polygon: lower resolutions only -------------------------------
# Res >= 9 on the Bay-Area-sized polygon would produce hundreds of
# thousands of cells and dominate total run time. Capped at res 8.

Benchee.run(
  %{
    "polyfill/2 (large polygon)" => fn res -> ExH3o.polyfill(large_polygon, res) end
  },
  inputs: [
    {"res=5", 5},
    {"res=7", 7},
    {"res=8", 8}
  ],
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false],
  title: "polyfill/2 — large polygon (~100 km\u00B2 Bay Area)"
)
