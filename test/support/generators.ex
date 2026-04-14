defmodule ExH3o.Generators do
  @moduledoc false

  use ExUnitProperties

  @doc """
  Generates a valid H3 resolution (integer 0..15).
  """
  @spec valid_resolution() :: StreamData.t(0..15)
  def valid_resolution, do: integer(0..15)

  @doc """
  Generates a valid `{lat, lng}` coordinate tuple.

  Latitude is in [-90, 90], longitude is in [-180, 180].
  No NaN or Infinity values.
  """
  @spec valid_coordinate() :: StreamData.t({float(), float()})
  def valid_coordinate do
    gen all(
          lat <- float(min: -90.0, max: 90.0),
          lng <- float(min: -180.0, max: 180.0)
        ) do
      {lat, lng}
    end
  end

  @doc """
  Generates a valid H3 cell index by geocoding a random coordinate.

  When `resolution` is `nil`, a random resolution is chosen.
  """
  @spec valid_cell(0..15 | nil) :: StreamData.t(non_neg_integer())
  def valid_cell(resolution \\ nil) do
    gen all(
          coord <- valid_coordinate(),
          res <- resolution_generator(resolution)
        ) do
      ExH3o.from_geo(coord, res)
    end
  end

  @doc """
  Generates a list of `count` valid H3 cells all at the same resolution.
  """
  @spec valid_cell_set(0..15, pos_integer()) :: StreamData.t([non_neg_integer()])
  def valid_cell_set(resolution, count) when count > 0 do
    gen all(coords <- list_of(valid_coordinate(), length: count)) do
      Enum.map(coords, fn coord -> ExH3o.from_geo(coord, resolution) end)
    end
  end

  @doc """
  Generates a convex polygon as a list of `{lat, lng}` vertex tuples.

  Produces vertices arranged in a circle around a random center point,
  guaranteeing convexity.
  """
  @spec valid_polygon(pos_integer()) :: StreamData.t([{float(), float()}])
  def valid_polygon(vertex_count) when vertex_count >= 3 do
    gen all(
          center_lat <- float(min: -80.0, max: 80.0),
          center_lng <- float(min: -170.0, max: 170.0),
          radius <- float(min: 0.01, max: 1.0)
        ) do
      for i <- 0..(vertex_count - 1) do
        angle = 2 * :math.pi() * i / vertex_count
        lat = center_lat + radius * :math.cos(angle)
        lng = center_lng + radius * :math.sin(angle)
        {clamp(lat, -90.0, 90.0), clamp(lng, -180.0, 180.0)}
      end
    end
  end

  defp resolution_generator(nil), do: valid_resolution()
  defp resolution_generator(res) when res in 0..15, do: constant(res)

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
