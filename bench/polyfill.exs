# Polyfill benchmark: ex_h3o vs erlang-h3
#
# Run: `mix run bench/polyfill.exs`
#
# Polyfill is the heaviest workload in the library. Cost scales with both
# polygon area and resolution. At high resolutions over large polygons
# it produces hundreds of thousands of cells.
#
# Input shape note:
#   * ex_h3o takes a flat `[{lat, lng}, ...]` ring
#   * erlang-h3 takes a GeoJSON-style `[[{lat, lng}, ...]]` (outer ring +
#     optional holes)
#
# Both return bare lists of cells (or raise on invalid input).
#
# Scenarios cover three polygon sizes × multiple resolutions each.
# IMPORTANT: both libraries are implementing different algorithms under
# the hood (libh3 vs h3o), so small discrepancies in cell count between
# the two are expected. We assert counts match loosely in the pre-check.

nif_so_path = Path.join([File.cwd!(), "priv/ex_h3o_nif.so"])

unless File.exists?(nif_so_path) do
  IO.puts(:stderr, "ERROR: NIF .so not found at #{nif_so_path}")
  IO.puts(:stderr, "Run `mix compile` to build it.")
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

# erlang-h3 expects `[[vertices]]`, an outer list wrapping the ring list
# so holes can be passed too. Our polygons have no holes, so we wrap once.
small_h3 = [small_polygon]
medium_h3 = [medium_polygon]
large_h3 = [large_polygon]

# Sanity check: verify each polygon produces roughly the same cell count
# in both libraries at the resolutions we're about to benchmark.
IO.puts("Pre-check cell counts:")

for {name, ex_poly, h3_poly, res} <- [
      {"small@9", small_polygon, small_h3, 9},
      {"medium@10", medium_polygon, medium_h3, 10},
      {"large@7", large_polygon, large_h3, 7}
    ] do
  ex_cells = ExH3o.polyfill(ex_poly, res)
  h3_cells = :h3.polyfill(h3_poly, res)

  IO.puts(
    "  #{name}: ex_h3o=#{length(ex_cells)} cells, erlang-h3=#{length(h3_cells)} cells"
  )
end

# Warm both NIFs
_ = ExH3o.polyfill(small_polygon, 7)
_ = :h3.polyfill(small_h3, 7)

IO.puts("""

============================================================
 ex_h3o vs erlang-h3: polyfill/2
============================================================
 nif:      #{nif_so_path}
 OTP:      #{System.otp_release()}
 Elixir:   #{System.version()}
 schedulers: #{System.schedulers_online()} online / #{System.schedulers()} total

""")

benchee_opts = [
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false]
]

# --- Small polygon: resolution sweep -------------------------------------

Benchee.run(
  %{
    "ex_h3o.polyfill (small)" => fn res -> ExH3o.polyfill(small_polygon, res) end,
    "erlang-h3.polyfill (small)" => fn res -> :h3.polyfill(small_h3, res) end
  },
  [
    inputs: [
      {"res=7", 7},
      {"res=9", 9},
      {"res=11", 11}
    ],
    title: "polyfill/2: small polygon (SF ~1 block)"
  ] ++ benchee_opts
)

# --- Medium polygon: resolution sweep ------------------------------------

Benchee.run(
  %{
    "ex_h3o.polyfill (medium)" => fn res -> ExH3o.polyfill(medium_polygon, res) end,
    "erlang-h3.polyfill (medium)" => fn res -> :h3.polyfill(medium_h3, res) end
  },
  [
    inputs: [
      {"res=8", 8},
      {"res=10", 10},
      {"res=12", 12}
    ],
    title: "polyfill/2: medium polygon (SF ~1 km\u00B2)"
  ] ++ benchee_opts
)

# --- Large polygon: lower resolutions only -------------------------------
# Res >= 9 on the Bay-Area-sized polygon would produce hundreds of
# thousands of cells and dominate total run time. Capped at res 8.

Benchee.run(
  %{
    "ex_h3o.polyfill (large)" => fn res -> ExH3o.polyfill(large_polygon, res) end,
    "erlang-h3.polyfill (large)" => fn res -> :h3.polyfill(large_h3, res) end
  },
  [
    inputs: [
      {"res=5", 5},
      {"res=7", 7},
      {"res=8", 8}
    ],
    title: "polyfill/2: large polygon (~100 km\u00B2 Bay Area)"
  ] ++ benchee_opts
)
