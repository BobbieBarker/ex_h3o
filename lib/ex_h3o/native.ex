defmodule ExH3o.Native do
  @moduledoc false

  @rustler_features if Application.compile_env(:ex_h3o, :include_test_utils, false),
                      do: ["test_utils"],
                      else: []

  use Rustler,
    otp_app: :ex_h3o,
    crate: "ex_h3o_nif",
    features: @rustler_features

  @spec is_valid(non_neg_integer()) :: boolean()
  def is_valid(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec get_resolution(non_neg_integer()) :: {:ok, 0..15} | {:error, :invalid_index}
  def get_resolution(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec get_base_cell(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, :invalid_index}
  def get_base_cell(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec is_pentagon(non_neg_integer()) :: {:ok, boolean()} | {:error, :invalid_index}
  def is_pentagon(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec is_class3(non_neg_integer()) :: {:ok, boolean()} | {:error, :invalid_index}
  def is_class3(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec parent(non_neg_integer(), 0..15) ::
          {:ok, non_neg_integer()} | {:error, :invalid_index | :invalid_resolution}
  def parent(_cell, _resolution), do: :erlang.nif_error(:nif_not_loaded)

  @spec children(non_neg_integer(), 0..15) ::
          {:ok, binary()} | {:error, :invalid_index | :invalid_resolution}
  def children(_cell, _resolution), do: :erlang.nif_error(:nif_not_loaded)

  @spec indices_are_neighbors(non_neg_integer(), non_neg_integer()) ::
          {:ok, boolean()} | {:error, :invalid_index | :resolution_mismatch}
  def indices_are_neighbors(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @spec grid_distance(non_neg_integer(), non_neg_integer()) ::
          {:ok, integer()} | {:error, :invalid_index | :local_ij_error}
  def grid_distance(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @spec get_unidirectional_edge(non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_index | :not_neighbors}
  def get_unidirectional_edge(_origin, _destination), do: :erlang.nif_error(:nif_not_loaded)

  @spec k_ring(non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :invalid_index}
  def k_ring(_cell, _k), do: :erlang.nif_error(:nif_not_loaded)

  if Application.compile_env(:ex_h3o, :include_test_utils, false) do
    @doc false
    @spec dirty_sleep(non_neg_integer()) :: :ok
    def dirty_sleep(_ms), do: :erlang.nif_error(:nif_not_loaded)
  end
end
