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

  @spec from_geo(float(), float(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_coordinates | :invalid_resolution}
  def from_geo(_lat, _lng, _resolution), do: :erlang.nif_error(:nif_not_loaded)

  @spec to_geo(non_neg_integer()) :: {:ok, {float(), float()}} | {:error, :invalid_index}
  def to_geo(_cell), do: :erlang.nif_error(:nif_not_loaded)

  @spec to_geo_boundary(non_neg_integer()) :: {:ok, binary()} | {:error, :invalid_index}
  def to_geo_boundary(_cell), do: :erlang.nif_error(:nif_not_loaded)

  if Application.compile_env(:ex_h3o, :include_test_utils, false) do
    @doc false
    @spec dirty_sleep(non_neg_integer()) :: :ok
    def dirty_sleep(_ms), do: :erlang.nif_error(:nif_not_loaded)
  end
end
