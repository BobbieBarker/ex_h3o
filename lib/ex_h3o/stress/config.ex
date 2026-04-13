defmodule ExH3o.Stress.Config do
  @moduledoc """
  Tunable parameters for the `ExH3o.Stress.Harness` load generator.

  The harness is NOT an ExUnit test — it is a development tool for probing
  the dirty CPU scheduler behavior of collection-returning NIFs under
  concurrent load. Every knob must be configurable at the call site; none
  are hardcoded in the harness body. This is the performance-engineer
  specialist pillar #4.

  ## Fields

    * `:operation` — which NIF to hammer. One of `:k_ring`, `:k_ring_distances`,
      `:children`, `:compact`, `:uncompact`, `:polyfill`. Default: `:k_ring`.
    * `:concurrency` — number of concurrent worker processes. Default: `100`.
    * `:iterations` — operations per worker (total ops = `concurrency * iterations`).
      Default: `2_000`.
    * `:warmup_iterations` — ops per worker before the measured run.
      Primes caches, NIF code, and stabilizes JIT. Default: `200`.
    * `:k_ring_k` — k value used for `:k_ring` and `:k_ring_distances`
      operations. Higher k produces more cells per call, more allocation
      pressure. Default: `2`.
    * `:children_descent` — how many resolution levels `:children` descends
      (1 = 7 cells, 2 = 49, 3 = 343). Default: `2`.
    * `:polyfill_vertices` — polygon to use for `:polyfill`. Defaults to a
      ~1 km² square in San Francisco.
    * `:polyfill_resolution` — resolution for `:polyfill` calls. Default: `9`.
    * `:base_coord` — `{lat, lng}` coordinate used to derive the base cell
      for operations that take a single cell as input (`:k_ring`, `:children`,
      etc.). Default: `{37.7749, -122.4194}` (San Francisco).
    * `:base_resolution` — resolution of the base cell. Default: `9`.
    * `:msacc_sample_interval_ms` — how often the msacc sampler reads stats
      during the run. 100 ms is the recommended default per
      `docs/msacc-stress-testing.md`; finer intervals add overhead without
      meaningful resolution improvement. Default: `100`.
    * `:report_json_path` — if set, harness writes a JSON copy of the
      report to this path. Default: `nil`.

  ## Example

      %ExH3o.Stress.Config{
        operation: :k_ring,
        concurrency: 100,
        iterations: 2_000,
        k_ring_k: 2
      }

  These defaults match the acceptance criterion from the PRD (concurrency=100,
  iterations=2000, k_ring_k=2).
  """

  @type operation ::
          :k_ring
          | :k_ring_distances
          | :children
          | :compact
          | :uncompact
          | :polyfill

  @type t :: %__MODULE__{
          operation: operation(),
          concurrency: pos_integer(),
          iterations: pos_integer(),
          warmup_iterations: non_neg_integer(),
          k_ring_k: non_neg_integer(),
          children_descent: pos_integer(),
          polyfill_vertices: [{float(), float()}],
          polyfill_resolution: 0..15,
          base_coord: {float(), float()},
          base_resolution: 0..15,
          msacc_sample_interval_ms: pos_integer(),
          report_json_path: String.t() | nil
        }

  @default_polyfill_vertices [
    {37.7700, -122.4200},
    {37.7700, -122.4100},
    {37.7800, -122.4100},
    {37.7800, -122.4200},
    {37.7700, -122.4200}
  ]

  defstruct operation: :k_ring,
            concurrency: 100,
            iterations: 2_000,
            warmup_iterations: 200,
            k_ring_k: 2,
            children_descent: 2,
            polyfill_vertices: @default_polyfill_vertices,
            polyfill_resolution: 9,
            base_coord: {37.7749, -122.4194},
            base_resolution: 9,
            msacc_sample_interval_ms: 100,
            report_json_path: nil

  @doc """
  Returns the default configuration.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Builds a config from a keyword list of overrides, applied on top of
  `default/0`.

      Config.new(concurrency: 50, iterations: 500)
  """
  @spec new(keyword()) :: t()
  def new(overrides) when is_list(overrides) do
    struct!(__MODULE__, overrides)
  end
end
