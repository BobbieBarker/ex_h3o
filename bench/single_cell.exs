# Single-cell operations benchmark
#
# Run: `mix run bench/single_cell.exs`
#
# Measures fast O(1) NIFs: from_geo, to_geo, is_valid, get_resolution,
# get_base_cell, is_pentagon, is_class3, to_string, from_string.
#
# These are all expected to be sub-microsecond on release-mode builds.
# Per benchee-patterns.md Pattern 3, we use `max_sample_size: 100_000`
# to prevent Benchee from accumulating GB of samples on fast functions.

# Pillar #1 enforcement: the dylib path must be under target/release/.
# We force `mode: :release` in lib/ex_h3o/native.ex so this should always
# be true, but we verify at startup anyway — pillars are non-negotiable.
dylib_path =
  Path.join([
    File.cwd!(),
    "native/ex_h3o_nif/target/release/libex_h3o_nif.dylib"
  ])

unless File.exists?(dylib_path) do
  IO.puts(:stderr, """
  ERROR: release-mode NIF dylib not found at:
    #{dylib_path}

  Benchmarks MUST run against release-mode NIFs. Debug builds are orders
  of magnitude slower and produce misleading numbers.

  Rebuild with: `mix compile --force`
  """)

  System.halt(1)
end

# Derive a known-valid H3 cell at resolution 9 from a coordinate (SF).
# Hardcoding cell indices is brittle — the h3o crate validates bit patterns
# strictly and the "obvious" hex literals from examples may be truncated.
{lat, lng} = {37.7749, -122.4194}
{:ok, cell} = ExH3o.from_geo({lat, lng}, 9)
invalid_cell = 0
{:ok, hex_string} = ExH3o.to_string(cell)

# Warm the NIF — first call may pay one-time init cost.
_ = ExH3o.is_valid(cell)
_ = ExH3o.from_geo({lat, lng}, 9)
_ = ExH3o.to_geo(cell)

IO.puts("""

============================================================
 ex_h3o single-cell benchmark
============================================================
 dylib:    #{dylib_path}
 OTP:      #{System.otp_release()}
 Elixir:   #{System.version()}
 schedulers: #{System.schedulers_online()} online / #{System.schedulers()} total

""")

Benchee.run(
  %{
    "is_valid/1 (valid cell)" => fn -> ExH3o.is_valid(cell) end,
    "is_valid/1 (invalid cell)" => fn -> ExH3o.is_valid(invalid_cell) end,
    "from_geo/2 res=9" => fn -> ExH3o.from_geo({lat, lng}, 9) end,
    "to_geo/1" => fn -> ExH3o.to_geo(cell) end,
    "get_resolution/1" => fn -> ExH3o.get_resolution(cell) end,
    "get_base_cell/1" => fn -> ExH3o.get_base_cell(cell) end,
    "is_pentagon/1" => fn -> ExH3o.is_pentagon(cell) end,
    "is_class3/1" => fn -> ExH3o.is_class3(cell) end,
    "to_string/1" => fn -> ExH3o.to_string(cell) end,
    "from_string/1" => fn -> ExH3o.from_string(hex_string) end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  pre_check: true,
  max_sample_size: 100_000,
  print: [fast_warning: false],
  formatters: [
    Benchee.Formatters.Console
  ],
  title: "ex_h3o single-cell operations"
)
