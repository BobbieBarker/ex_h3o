# Stress harness entry point. All logic lives in ExH3o.Stress.Runner.
#
# Defaults: polyfill, library=ex_h3o, concurrency=100, iterations=2000.
#
#   mix run bench/stress.exs
#   mix run bench/stress.exs -- --operation round_trip
#   mix run bench/stress.exs -- --library erlang_h3 --operation polyfill
#   mix run bench/stress.exs -- --operation k_ring --k 10
#   mix run bench/stress.exs -- --operation children --concurrency 50 --iterations 500
#
# For a GC-pressure A/B test, run polyfill against both libraries
# back-to-back and compare dirty_cpu gc% / normal gc% / process GC
# count:
#
#   mix run bench/stress.exs -- --library erlang_h3 --operation polyfill
#   mix run bench/stress.exs -- --library ex_h3o    --operation polyfill

ExH3o.Stress.Runner.main(System.argv())
