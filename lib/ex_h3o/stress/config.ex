defmodule ExH3o.Stress.Config do
  @moduledoc """
  Tunable parameters for the `ExH3o.Stress.Harness` load generator.

  The harness is NOT an ExUnit test. It is a development tool for probing
  the dirty CPU scheduler behavior of collection-returning NIFs under
  concurrent load. Every knob is configurable at the call site; none are
  hardcoded in the harness body.

  ## Fields

    * `:library`: which H3 library to exercise. One of `:ex_h3o` (this
      library) or `:erlang_h3` (the reference `:h3` NIF from hex.pm). The
      erlang_h3 dispatch is used by `bench/stress.exs` so we can compare
      GC pressure side-by-side rather than just asserting ex_h3o numbers
      in isolation. Default: `:ex_h3o`.
    * `:operation`: which NIF to hammer. One of `:k_ring`, `:k_ring_distances`,
      `:children`, `:compact`, `:uncompact`, `:polyfill`, `:round_trip`,
      `:mixed_chain`.
      `:round_trip` is a simple `to_geo` + `get_resolution` + `from_geo`
      chain. Every call allocates a `{lat, lng}` tuple and a new cell
      integer, exercising small-allocation GC pressure on the calling
      process heap.
      `:mixed_chain` rotates a set of seed cells across workers and,
      per iteration, calls `k_ring(cell, k)` + `children(cell, 10)` +
      `parent(cell, 8)` + round_trip as a group. It's a realistic
      multi-op hot path that stresses both collection and scalar NIFs
      together, available for both `:ex_h3o` and `:erlang_h3`. Default:
      `:polyfill`.
    * `:concurrency`: number of concurrent worker processes. Default: `100`.
    * `:iterations`: operations per worker (total ops = `concurrency * iterations`).
      Default: `2_000`.
    * `:warmup_iterations`: ops per worker before the measured run.
      Primes caches, NIF code, and stabilizes JIT. Default: `200`.
    * `:k_ring_k`: k value used for `:k_ring` and `:k_ring_distances`
      operations. Higher k produces more cells per call, more allocation
      pressure. Default: `2`.
    * `:children_descent`: how many resolution levels `:children` descends
      (1 = 7 cells, 2 = 49, 3 = 343). Default: `2`.
    * `:polyfill_vertices`: polygon to use for `:polyfill`. Defaults to a
      ~1 km² square in San Francisco.
    * `:polyfill_resolution`: resolution for `:polyfill` calls. Default: `9`.
    * `:base_coord`: `{lat, lng}` coordinate used to derive the base cell
      for operations that take a single cell as input (`:k_ring`, `:children`,
      etc.). Default: `{37.7749, -122.4194}` (San Francisco).
    * `:base_resolution`: resolution of the base cell. Default: `9`.
    * `:msacc_sample_interval_ms`: how often the msacc sampler reads stats
      during the run. 100 ms is a reasonable default; finer intervals
      add overhead without meaningful resolution improvement. Default:
      `100`.
    * `:duration_seconds`: if set (non-nil positive integer), workers
      ignore `:iterations` and instead loop until this many wall-clock
      seconds have elapsed. Used by `bench/gc_deep_dive.exs` to capture
      steady-state behavior rather than cold-start artifacts. Default:
      `nil` (use `:iterations`).
    * `:track_per_worker_gc`: if true, each worker captures
      `:erlang.process_info(self(), [:garbage_collection_info,
      :total_heap_size, :memory])` before and after its loop. Adds a tiny
      cost per worker (NOT per call), so safe to leave on. Default:
      `true`.
    * `:report_json_path`: if set, harness writes a JSON copy of the
      report to this path. Default: `nil`.

  ## Example

      %ExH3o.Stress.Config{
        operation: :k_ring,
        concurrency: 100,
        iterations: 2_000,
        k_ring_k: 2
      }
  """

  @type library :: :ex_h3o | :erlang_h3

  @type operation ::
          :k_ring
          | :k_ring_distances
          | :children
          | :compact
          | :uncompact
          | :polyfill
          | :round_trip
          | :mixed_chain
          | :null_nif
          | :null_nif_dirty
          | :is_valid
          | :from_geo
          | :to_geo
          | :get_resolution

  @type t :: %__MODULE__{
          library: library(),
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
          duration_seconds: pos_integer() | nil,
          track_per_worker_gc: boolean(),
          report_json_path: String.t() | nil
        }

  @default_polyfill_vertices [
    {37.7700, -122.4200},
    {37.7700, -122.4100},
    {37.7800, -122.4100},
    {37.7800, -122.4200},
    {37.7700, -122.4200}
  ]

  defstruct library: :ex_h3o,
            operation: :polyfill,
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
            duration_seconds: nil,
            track_per_worker_gc: true,
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
