defmodule ExH3o.Native do
  @moduledoc false
  # NIF stub module. Every function here raises `:nif_not_loaded` at
  # compile time and is replaced at BEAM load by the native
  # implementation in `priv/ex_h3o_nif.so`.
  #
  # Two load modes:
  #
  #   1. **Precompiled** (default) — `RustlerPrecompiled` downloads a
  #      pre-built `.so`/`.dylib`/`.dll` from the GitHub release that
  #      matches the package version and host target triple.
  #
  #   2. **Source build** (`EX_H3O_BUILD=true`) — `elixir_make` drives
  #      `native/ex_h3o_nif/Makefile`, which runs `cargo build` + `cc`
  #      to produce `priv/ex_h3o_nif.so` locally.
  #
  # All return shapes are BARE values, no `{:ok, _} | {:error, _}`
  # unions. Invalid inputs raise `ArgumentError` from the C NIF via
  # `enif_make_badarg`. This matches the erlang-h3 / Pattern C contract.

  if System.get_env("EX_H3O_BUILD") in ["1", "true"] do
    @on_load :load_nif

    @spec load_nif() :: :ok | {:error, term()}
    def load_nif do
      path = :filename.join(:code.priv_dir(:ex_h3o), ~c"ex_h3o_nif")
      :erlang.load_nif(path, 0)
    end
  else
    @version Mix.Project.config()[:version]

    use RustlerPrecompiled,
      otp_app: :ex_h3o,
      crate: "ex_h3o_nif",
      base_url: "https://github.com/bobbiebarker/ex_h3o/releases/download/v#{@version}",
      version: @version,
      targets: ~w(
        aarch64-apple-darwin
        aarch64-unknown-linux-gnu
        aarch64-unknown-linux-musl
        arm-unknown-linux-gnueabihf
        riscv64gc-unknown-linux-gnu
        x86_64-apple-darwin
        x86_64-pc-windows-gnu
        x86_64-pc-windows-msvc
        x86_64-unknown-linux-gnu
        x86_64-unknown-linux-musl
      )
  end

  # --- Single-cell scalar ops (normal scheduler) -------------------------

  @spec is_valid(non_neg_integer()) :: boolean()
  def is_valid(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec get_resolution(non_neg_integer()) :: 0..15
  def get_resolution(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec get_base_cell(non_neg_integer()) :: non_neg_integer()
  def get_base_cell(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec is_pentagon(non_neg_integer()) :: boolean()
  def is_pentagon(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec is_class3(non_neg_integer()) :: boolean()
  def is_class3(_cell), do: :erlang.nif_error(:nif_not_loaded)

  # --- Hex string conversion ---------------------------------------------

  @spec from_string(String.t()) :: non_neg_integer()
  def from_string(_hex), do: :erlang.nif_error(:nif_not_loaded)

  @spec to_string(non_neg_integer()) :: binary()
  def to_string(_cell), do: :erlang.nif_error(:nif_not_loaded)

  # --- Geo <-> cell conversion -------------------------------------------

  @spec from_geo(float(), float(), 0..15) :: non_neg_integer()
  def from_geo(_lat, _lng, _resolution), do: :erlang.nif_error(:nif_not_loaded)

  @spec to_geo(non_neg_integer()) :: {float(), float()}
  def to_geo(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec to_geo_boundary(non_neg_integer()) :: [{float(), float()}, ...]
  def to_geo_boundary(_cell), do: :erlang.nif_error(:nif_not_loaded)

  # --- Hierarchy ---------------------------------------------------------

  @spec parent(non_neg_integer(), 0..15) :: non_neg_integer()
  def parent(_cell, _resolution), do: :erlang.nif_error(:nif_not_loaded)

  @spec children(non_neg_integer(), 0..15) :: [non_neg_integer()]
  def children(_cell, _resolution), do: :erlang.nif_error(:nif_not_loaded)

  # --- Neighbors / distance / edges --------------------------------------

  @spec indices_are_neighbors(non_neg_integer(), non_neg_integer()) :: boolean()
  def indices_are_neighbors(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @spec grid_distance(non_neg_integer(), non_neg_integer()) :: integer()
  def grid_distance(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @spec get_unidirectional_edge(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def get_unidirectional_edge(_origin, _destination), do: :erlang.nif_error(:nif_not_loaded)

  # --- Grid disk family --------------------------------------------------

  @spec k_ring(non_neg_integer(), non_neg_integer()) :: [non_neg_integer()]
  def k_ring(_cell, _k), do: :erlang.nif_error(:nif_not_loaded)

  @spec k_ring_distances(non_neg_integer(), non_neg_integer()) ::
          [{non_neg_integer(), non_neg_integer()}]
  def k_ring_distances(_cell, _k), do: :erlang.nif_error(:nif_not_loaded)

  # --- Compact / uncompact (dirty CPU) -----------------------------------

  @spec compact(binary()) :: [non_neg_integer()]
  def compact(_packed), do: :erlang.nif_error(:nif_not_loaded)

  @spec uncompact(binary(), 0..15) :: [non_neg_integer()]
  def uncompact(_packed, _resolution), do: :erlang.nif_error(:nif_not_loaded)

  # --- Polyfill (dirty CPU) ----------------------------------------------

  @spec polyfill(binary(), 0..15) :: [non_neg_integer()]
  def polyfill(_packed_coords, _resolution), do: :erlang.nif_error(:nif_not_loaded)

  # --- Bench helpers -----------------------------------------------------

  # Zero-work NIFs used by the stress harness to isolate FFI dispatch
  # cost from real algorithm work. Both call the same Rust body; only
  # the scheduler flag differs.
  @doc false
  @spec null_nif() :: :ok
  def null_nif, do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec null_nif_dirty() :: :ok
  def null_nif_dirty, do: :erlang.nif_error(:nif_not_loaded)

  # --- Test helper -------------------------------------------------------

  # Used by test/ex_h3o_shutdown_test.exs to verify that
  # ERL_NIF_OPT_DELAY_HALT lets in-flight dirty NIFs complete before the
  # VM halts.
  @doc false
  @spec dirty_sleep(non_neg_integer()) :: :ok
  def dirty_sleep(_ms), do: :erlang.nif_error(:nif_not_loaded)
end
