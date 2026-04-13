defmodule ExH3o.Native do
  @moduledoc false

  use Rustler,
    otp_app: :ex_h3o,
    crate: "ex_h3o_nif"

  @spec is_valid(non_neg_integer()) :: boolean()
  def is_valid(_cell), do: :erlang.nif_error(:nif_not_loaded)
end
