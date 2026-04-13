# Stress harness entry point — all logic lives in ExH3o.Stress.Runner.
#
# Defaults: k_ring, concurrency=100, iterations=2000, k=2, resolution=9.
#
#   mix run bench/stress.exs
#   mix run bench/stress.exs -- --operation polyfill
#   mix run bench/stress.exs -- --operation k_ring --k 10
#   mix run bench/stress.exs -- --operation children --concurrency 50 --iterations 500

ExH3o.Stress.Runner.main(System.argv())
