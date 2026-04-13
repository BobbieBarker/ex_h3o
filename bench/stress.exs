# Stress harness entry point
#
# Run with defaults (k_ring, concurrency=100, iterations=2000, k=2):
#   mix run bench/stress.exs
#
# Run for a different operation:
#   mix run bench/stress.exs -- --operation polyfill
#   mix run bench/stress.exs -- --operation k_ring --k 10
#
# Every knob is configurable so individual runs can be reproduced for
# diagnosing regressions.

dylib_path =
  Path.join([
    File.cwd!(),
    "native/ex_h3o_nif/target/release/libex_h3o_nif.dylib"
  ])

unless File.exists?(dylib_path) do
  IO.puts(:stderr, """
  ERROR: release-mode NIF dylib not found at:
    #{dylib_path}

  Stress harness MUST run against release-mode NIFs. Rebuild with:
    mix compile --force
  """)

  System.halt(1)
end

# `mix run script.exs -- --flag value` passes `["--", "--flag", "value"]`
# to System.argv/0 because `--` is the POSIX end-of-options separator.
# OptionParser treats `--` the same way and stops parsing. Strip it so
# both `mix run stress.exs --operation polyfill` and
# `mix run stress.exs -- --operation polyfill` work.
argv =
  case System.argv() do
    ["--" | rest] -> rest
    other -> other
  end

{opts, _, _} =
  OptionParser.parse(argv,
    strict: [
      operation: :string,
      concurrency: :integer,
      iterations: :integer,
      warmup: :integer,
      k: :integer,
      resolution: :integer,
      children_descent: :integer,
      polyfill_resolution: :integer,
      json: :string
    ]
  )

op =
  case Keyword.get(opts, :operation, "k_ring") do
    "k_ring" -> :k_ring
    "k_ring_distances" -> :k_ring_distances
    "children" -> :children
    "compact" -> :compact
    "uncompact" -> :uncompact
    "polyfill" -> :polyfill
    other ->
      IO.puts(:stderr, "Unknown operation: #{other}")
      System.halt(1)
  end

config =
  ExH3o.Stress.Config.new(
    operation: op,
    concurrency: Keyword.get(opts, :concurrency, 100),
    iterations: Keyword.get(opts, :iterations, 2_000),
    warmup_iterations: Keyword.get(opts, :warmup, 200),
    k_ring_k: Keyword.get(opts, :k, 2),
    base_resolution: Keyword.get(opts, :resolution, 9),
    children_descent: Keyword.get(opts, :children_descent, 2),
    polyfill_resolution: Keyword.get(opts, :polyfill_resolution, 9),
    report_json_path: Keyword.get(opts, :json)
  )

IO.puts("""

Starting ex_h3o stress harness
  operation:    #{config.operation}
  concurrency:  #{config.concurrency}
  iterations:   #{config.iterations} per worker
  total ops:    #{config.concurrency * config.iterations}
  warmup:       #{config.warmup_iterations} per worker
""")

report = ExH3o.Stress.Harness.run(config)
ExH3o.Stress.Harness.print_report(report)

case config.report_json_path do
  nil ->
    :ok

  path ->
    json_data = ExH3o.Stress.Harness.to_map(report) |> inspect(pretty: true, limit: :infinity)
    File.write!(path, json_data)
    IO.puts("Report written to #{path}")
end
