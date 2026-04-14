# Collection-returning NIFs: ex_h3o vs erlang-h3
#
# Run: `mix run bench/collections.exs`
#
# Covers:
#   * k_ring/2 at k = 1, 5, 10, 20 (7, 91, 331, 1261 cells)
#   * k_ring_distances/2 at k = 1, 5, 10 (same shapes + distance pairs)
#   * children/2 at +1, +2, +3 resolution levels (7, 49, 343 cells)
#   * compact/1 (dense 7-cell k_ring -> parent)
#   * uncompact/2 (inverse of the above)
#
# Both libraries return bare BEAM lists of cells (or {cell, distance}
# tuples for k_ring_distances, {lat, lng} for to_geo_boundary).

nif_so_path = Path.join([File.cwd!(), "priv/ex_h3o_nif.so"])

unless File.exists?(nif_so_path) do
  IO.puts(:stderr, "ERROR: NIF .so not found at #{nif_so_path}")
  IO.puts(:stderr, "Run `mix compile` to build it.")
  System.halt(1)
end

# Known-good cell at resolution 9 (San Francisco)
cell = ExH3o.from_geo({37.7749, -122.4194}, 9)

# Warm both NIFs once so we don't pay cold-start cost in the first scenario.
_ = ExH3o.k_ring(cell, 1)
_ = :h3.k_ring(cell, 1)

IO.puts("""

============================================================
 ex_h3o vs erlang-h3: collection operations
============================================================
 nif:      #{nif_so_path}
 OTP:      #{System.otp_release()}
 Elixir:   #{System.version()}
 schedulers: #{System.schedulers_online()} online / #{System.schedulers()} total
 cell:     #{cell} (res 9, SF)

""")

benchee_opts = [
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false]
]

# --- k_ring scaling ------------------------------------------------------

Benchee.run(
  %{
    "ex_h3o.k_ring/2" => fn k -> ExH3o.k_ring(cell, k) end,
    "erlang-h3.k_ring/2" => fn k -> :h3.k_ring(cell, k) end
  },
  [
    inputs: [
      {"k=1 (7 cells)", 1},
      {"k=5 (91 cells)", 5},
      {"k=10 (331 cells)", 10},
      {"k=20 (1261 cells)", 20}
    ],
    title: "k_ring/2 scaling"
  ] ++ benchee_opts
)

# --- k_ring_distances scaling --------------------------------------------
#
# NOTE: return shapes differ significantly here.
# ex_h3o returns `[{cell, distance}, ...]` (list of 2-tuples).
# erlang-h3 returns `[[cells_at_dist_0], [cells_at_dist_1], ...]`
# (list of lists, indexed by distance). Both shapes are measured
# as-is. Decoding the distance dimension is part of the NIF's work.

Benchee.run(
  %{
    "ex_h3o.k_ring_distances/2" => fn k -> ExH3o.k_ring_distances(cell, k) end,
    "erlang-h3.k_ring_distances/2" => fn k -> :h3.k_ring_distances(cell, k) end
  },
  [
    inputs: [
      {"k=1", 1},
      {"k=5", 5},
      {"k=10", 10}
    ],
    title: "k_ring_distances/2 scaling"
  ] ++ benchee_opts
)

# --- children scaling across resolution levels ---------------------------
# res 5 cell has 7 res-6 children, 49 res-7 children, 343 res-8 children.
res5_cell = ExH3o.from_geo({37.7749, -122.4194}, 5)

Benchee.run(
  %{
    "ex_h3o.children/2" => fn res -> ExH3o.children(res5_cell, res) end,
    "erlang-h3.children/2" => fn res -> :h3.children(res5_cell, res) end
  },
  [
    inputs: [
      {"+1 level (7 cells)", 6},
      {"+2 levels (49 cells)", 7},
      {"+3 levels (343 cells)", 8}
    ],
    title: "children/2 scaling"
  ] ++ benchee_opts
)

# --- compact / uncompact roundtrip ---------------------------------------
# Build a full set of children at res 9 from a res 8 cell: 7 children
# that compact/1 can collapse back to the single parent.
parent_cell = ExH3o.from_geo({37.7749, -122.4194}, 8)
dense_children = ExH3o.children(parent_cell, 9)

Benchee.run(
  %{
    "ex_h3o.compact/1" => fn -> ExH3o.compact(dense_children) end,
    "erlang-h3.compact/1" => fn -> :h3.compact(dense_children) end
  },
  [title: "compact/1 (7 children -> 1 parent)"] ++ benchee_opts
)

Benchee.run(
  %{
    "ex_h3o.uncompact/2" => fn -> ExH3o.uncompact([parent_cell], 9) end,
    "erlang-h3.uncompact/2" => fn -> :h3.uncompact([parent_cell], 9) end
  },
  [title: "uncompact/2 (1 parent -> 7 children)"] ++ benchee_opts
)

# --- larger-scale k_ring (amortization check) ----------------------------
#
# k=20 gives 1261 cells, but the real packed-binary story only shows up
# when the decode cost dominates the NIF call wrapper overhead. Run a
# k=30 scenario (2791 cells) and k=50 (7651 cells) to see whether the
# ex_h3o gap narrows or inverts as the payload grows.

Benchee.run(
  %{
    "ex_h3o.k_ring/2" => fn k -> ExH3o.k_ring(cell, k) end,
    "erlang-h3.k_ring/2" => fn k -> :h3.k_ring(cell, k) end
  },
  [
    inputs: [
      {"k=30 (2791 cells)", 30},
      {"k=50 (7651 cells)", 50}
    ],
    title: "k_ring/2 amortization"
  ] ++ benchee_opts
)
