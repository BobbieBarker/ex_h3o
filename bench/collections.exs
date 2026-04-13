# Collection-returning NIFs: scaling benchmark
#
# Run: `mix run bench/collections.exs`
#
# Covers:
#   * k_ring/2 at k = 1, 5, 10, 20 (7, 91, 331, 1261 cells)
#   * k_ring_distances/2 at k = 1, 5, 10 (same shapes + distance pairs)
#   * children/2 at +1, +2, +3 resolution levels (7, 49, 343 cells)
#   * compact/1 (dense 7-cell k_ring → parent)
#   * uncompact/2 (inverse of the above)
#
# Each NIF is collection-returning, so this is where the packed-binary
# wire format should show its value versus a BEAM-list-returning approach.
# Once erlang-h3 is installed we add it as a second scenario and compare.

dylib_path =
  Path.join([
    File.cwd!(),
    "native/ex_h3o_nif/target/release/libex_h3o_nif.dylib"
  ])

unless File.exists?(dylib_path) do
  IO.puts(:stderr, "ERROR: release-mode NIF dylib not found at #{dylib_path}")
  System.halt(1)
end

# Known-good cell at resolution 9 (San Francisco)
{:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, 9)

# Warm the NIF once so we don't pay cold-start cost in the first scenario.
_ = ExH3o.k_ring(cell, 1)

IO.puts("""

============================================================
 ex_h3o collections benchmark
============================================================
 dylib:    #{dylib_path}
 OTP:      #{System.otp_release()}
 Elixir:   #{System.version()}
 schedulers: #{System.schedulers_online()} online / #{System.schedulers()} total
 cell:     #{inspect(cell)} (res 9, SF)

""")

# --- k_ring scaling ------------------------------------------------------

Benchee.run(
  %{
    "k_ring/2" => fn k -> ExH3o.k_ring(cell, k) end
  },
  inputs: [
    {"k=1 (7 cells)", 1},
    {"k=5 (91 cells)", 5},
    {"k=10 (331 cells)", 10},
    {"k=20 (1261 cells)", 20}
  ],
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false],
  title: "k_ring/2 scaling"
)

# --- k_ring_distances scaling --------------------------------------------

Benchee.run(
  %{
    "k_ring_distances/2" => fn k -> ExH3o.k_ring_distances(cell, k) end
  },
  inputs: [
    {"k=1", 1},
    {"k=5", 5},
    {"k=10", 10}
  ],
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false],
  title: "k_ring_distances/2 scaling"
)

# --- children scaling across resolution levels ---------------------------
# res 5 cell has 7 res-6 children, 49 res-7 children, 343 res-8 children.
{:ok, res5_cell} = ExH3o.from_geo({37.7749, -122.4194}, 5)

Benchee.run(
  %{
    "children/2" => fn res -> ExH3o.children(res5_cell, res) end
  },
  inputs: [
    {"+1 level (7 cells)", 6},
    {"+2 levels (49 cells)", 7},
    {"+3 levels (343 cells)", 8}
  ],
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false],
  title: "children/2 scaling"
)

# --- compact / uncompact roundtrip ---------------------------------------
# Build a full set of children at res 9 from a res 8 cell — 7 children
# that compact/1 can collapse back to the single parent.
{:ok, parent_cell} = ExH3o.from_geo({37.7749, -122.4194}, 8)
{:ok, dense_children} = ExH3o.children(parent_cell, 9)

Benchee.run(
  %{
    "compact/1 (7 children \u2192 1 parent)" => fn -> ExH3o.compact(dense_children) end,
    "uncompact/2 (1 parent \u2192 7 children)" => fn ->
      ExH3o.uncompact([parent_cell], 9)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false],
  title: "compact/uncompact roundtrip"
)
