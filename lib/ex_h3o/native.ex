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

  if Application.compile_env(:ex_h3o, :include_test_utils, false) do
    @doc false
    @spec dirty_sleep(non_neg_integer()) :: :ok
    def dirty_sleep(_ms), do: :erlang.nif_error(:nif_not_loaded)
  end
end
