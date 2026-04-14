# Single-cell operations benchmark: ex_h3o vs erlang-h3
#
# Run: `mix run bench/single_cell.exs`
#
# Measures fast O(1) NIFs head-to-head against the reference erlang-h3
# library. Each operation gets its own Benchee.run block so the comparison
# table is focused and readable.
#
# `max_sample_size: 100_000` prevents Benchee from accumulating unbounded
# samples on sub-microsecond operations.
#
# Both libraries use bare return values and raise on invalid input, so
# per-call BEAM memory is directly comparable.

nif_so_path = Path.join([File.cwd!(), "priv/ex_h3o_nif.so"])

unless File.exists?(nif_so_path) do
  IO.puts(:stderr, "ERROR: NIF .so not found at #{nif_so_path}")
  IO.puts(:stderr, "Run `mix compile` to build it.")
  System.halt(1)
end

{lat, lng} = {37.7749, -122.4194}
cell = ExH3o.from_geo({lat, lng}, 9)
invalid_cell = 0
hex_string = ExH3o.to_string(cell)
h3_hex_string = :h3.to_string(cell)

# Warm both NIFs
_ = ExH3o.is_valid(cell)
_ = :h3.is_valid(cell)
_ = ExH3o.from_geo({lat, lng}, 9)
_ = :h3.from_geo({lat, lng}, 9)

IO.puts("""

============================================================
 ex_h3o vs erlang-h3: single-cell operations
============================================================
 nif:      #{nif_so_path}
 OTP:      #{System.otp_release()}
 Elixir:   #{System.version()}
 schedulers: #{System.schedulers_online()} online
 sample cell: #{cell} (res 9, SF)

""")

benchee_opts = [
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false]
]

# --- is_valid ------------------------------------------------------------

Benchee.run(
  %{
    "ex_h3o.is_valid (valid)" => fn -> ExH3o.is_valid(cell) end,
    "erlang-h3.is_valid (valid)" => fn -> :h3.is_valid(cell) end,
    "ex_h3o.is_valid (invalid)" => fn -> ExH3o.is_valid(invalid_cell) end,
    "erlang-h3.is_valid (invalid)" => fn -> :h3.is_valid(invalid_cell) end
  },
  [title: "is_valid/1"] ++ benchee_opts
)

# --- from_geo ------------------------------------------------------------

Benchee.run(
  %{
    "ex_h3o.from_geo res=9" => fn -> ExH3o.from_geo({lat, lng}, 9) end,
    "erlang-h3.from_geo res=9" => fn -> :h3.from_geo({lat, lng}, 9) end
  },
  [title: "from_geo/2"] ++ benchee_opts
)

# --- to_geo --------------------------------------------------------------

Benchee.run(
  %{
    "ex_h3o.to_geo" => fn -> ExH3o.to_geo(cell) end,
    "erlang-h3.to_geo" => fn -> :h3.to_geo(cell) end
  },
  [title: "to_geo/1"] ++ benchee_opts
)

# --- get_resolution ------------------------------------------------------

Benchee.run(
  %{
    "ex_h3o.get_resolution" => fn -> ExH3o.get_resolution(cell) end,
    "erlang-h3.get_resolution" => fn -> :h3.get_resolution(cell) end
  },
  [title: "get_resolution/1"] ++ benchee_opts
)

# --- get_base_cell -------------------------------------------------------

Benchee.run(
  %{
    "ex_h3o.get_base_cell" => fn -> ExH3o.get_base_cell(cell) end,
    "erlang-h3.get_base_cell" => fn -> :h3.get_base_cell(cell) end
  },
  [title: "get_base_cell/1"] ++ benchee_opts
)

# --- is_pentagon / is_class3 --------------------------------------------

Benchee.run(
  %{
    "ex_h3o.is_pentagon" => fn -> ExH3o.is_pentagon(cell) end,
    "erlang-h3.is_pentagon" => fn -> :h3.is_pentagon(cell) end,
    "ex_h3o.is_class3" => fn -> ExH3o.is_class3(cell) end,
    "erlang-h3.is_class3" => fn -> :h3.is_class3(cell) end
  },
  [title: "is_pentagon/1 and is_class3/1"] ++ benchee_opts
)

# --- to_string / from_string --------------------------------------------
#
# NOTE: erlang-h3's to_string/1 returns a charlist (`~c"89283..."`),
# ExH3o returns an Elixir binary (`"89283..."`). The BEAM memory numbers
# differ significantly because charlists are lists of integers (~48
# bytes per char) while binaries are heap references (~24 bytes total
# for a short binary).

Benchee.run(
  %{
    "ex_h3o.to_string" => fn -> ExH3o.to_string(cell) end,
    "erlang-h3.to_string" => fn -> :h3.to_string(cell) end
  },
  [title: "to_string/1"] ++ benchee_opts
)

Benchee.run(
  %{
    "ex_h3o.from_string (binary)" => fn -> ExH3o.from_string(hex_string) end,
    "erlang-h3.from_string (charlist)" => fn -> :h3.from_string(h3_hex_string) end
  },
  [title: "from_string/1"] ++ benchee_opts
)
