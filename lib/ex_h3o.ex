defmodule ExH3o do
  @moduledoc """
  Elixir bindings for [h3o](https://github.com/HydroniumLabs/h3o), a Rust
  implementation of the H3 geospatial indexing system.

  H3 is a hierarchical hexagonal grid system that maps geographic coordinates
  to hexagonal cells at multiple resolutions (0-15). It is used for spatial
  indexing, analysis, and aggregation of geospatial data.
  """

  @doc """
  Returns whether `cell` is a valid H3 cell index.

  Accepts a non-negative integer representing an H3 cell index and returns
  `true` if it is valid, `false` otherwise. Raises `ArgumentError` on
  non-integer input.

  ## Examples

      iex> ExH3o.is_valid(0x8928308280fffff)
      true

      iex> ExH3o.is_valid(0)
      false
  """
  @spec is_valid(non_neg_integer()) :: boolean()
  defdelegate is_valid(cell), to: ExH3o.Native

  @doc """
  Converts geographic coordinates to an H3 cell index at the given resolution.

  Takes a `{lat, lng}` tuple and a resolution (0–15). Returns `{:ok, cell}`
  on success or an error tuple for invalid inputs.

  ## Examples

      iex> {:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, 9)
      iex> ExH3o.is_valid(cell)
      true

      iex> ExH3o.from_geo({91.0, 0.0}, 9)
      {:error, :invalid_coordinates}

      iex> ExH3o.from_geo({0.0, 0.0}, 16)
      {:error, :invalid_resolution}
  """
  @spec from_geo({float(), float()}, 0..15) ::
          {:ok, non_neg_integer()} | {:error, :invalid_coordinates | :invalid_resolution}
  def from_geo({lat, lng}, resolution) do
    ExH3o.Native.from_geo(lat, lng, resolution)
  end

  @doc """
  Converts an H3 cell index to its center geographic coordinates.

  Returns `{:ok, {lat, lng}}` where lat is in [-90, 90] and lng is in [-180, 180].

  ## Examples

      iex> {:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, 9)
      iex> {:ok, {lat, lng}} = ExH3o.to_geo(cell)
      iex> lat >= -90.0 and lat <= 90.0
      true

      iex> ExH3o.to_geo(0)
      {:error, :invalid_index}
  """
  @spec to_geo(non_neg_integer()) :: {:ok, {float(), float()}} | {:error, :invalid_index}
  defdelegate to_geo(cell), to: ExH3o.Native

  @doc """
  Returns the boundary vertices of an H3 cell.

  Returns `{:ok, vertices}` where vertices is a list of `{lat, lng}` tuples.
  Hexagonal cells have 6 vertices; pentagonal cells have 5.

  ## Examples

      iex> {:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, 9)
      iex> {:ok, vertices} = ExH3o.to_geo_boundary(cell)
      iex> length(vertices)
      6
  """
  @spec to_geo_boundary(non_neg_integer()) ::
          {:ok, [{float(), float()}, ...]} | {:error, :invalid_index}
  def to_geo_boundary(cell) do
    case ExH3o.Native.to_geo_boundary(cell) do
      {:ok, packed} ->
        vertices = for <<lat::native-float-64, lng::native-float-64 <- packed>>, do: {lat, lng}
        {:ok, vertices}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
