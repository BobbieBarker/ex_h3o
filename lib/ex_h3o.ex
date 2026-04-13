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
  Returns the resolution (0–15) of the given H3 cell index.

  ## Examples

      iex> ExH3o.get_resolution(0x8928308280fffff)
      {:ok, 9}

      iex> ExH3o.get_resolution(0)
      {:error, :invalid_index}
  """
  @spec get_resolution(non_neg_integer()) :: {:ok, 0..15} | {:error, :invalid_index}
  defdelegate get_resolution(cell), to: ExH3o.Native

  @doc """
  Returns the base cell number (0–121) of the given H3 cell index.

  ## Examples

      iex> {:ok, base} = ExH3o.get_base_cell(0x8928308280fffff)
      iex> base in 0..121
      true

      iex> ExH3o.get_base_cell(0)
      {:error, :invalid_index}
  """
  @spec get_base_cell(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, :invalid_index}
  defdelegate get_base_cell(cell), to: ExH3o.Native

  @doc """
  Returns whether the given H3 cell index is a pentagon.

  H3 has 12 pentagons at each resolution (one per icosahedron vertex).

  ## Examples

      iex> ExH3o.is_pentagon(0x8928308280fffff)
      {:ok, false}

      iex> ExH3o.is_pentagon(0x8009fffffffffff)
      {:ok, true}

      iex> ExH3o.is_pentagon(0)
      {:error, :invalid_index}
  """
  @spec is_pentagon(non_neg_integer()) :: {:ok, boolean()} | {:error, :invalid_index}
  defdelegate is_pentagon(cell), to: ExH3o.Native

  @doc """
  Returns whether the given H3 cell index is Class III.

  Class III cells occur at odd resolutions. Class II cells occur at even
  resolutions.

  ## Examples

      iex> ExH3o.is_class3(0x8928308280fffff)
      {:ok, true}

      iex> ExH3o.is_class3(0x8009fffffffffff)
      {:ok, false}

      iex> ExH3o.is_class3(0)
      {:error, :invalid_index}
  """
  @spec is_class3(non_neg_integer()) :: {:ok, boolean()} | {:error, :invalid_index}
  defdelegate is_class3(cell), to: ExH3o.Native

  @doc """
  Returns whether two H3 cell indices are neighbors (adjacent).

  Both cells must be at the same resolution. Returns `{:error, :resolution_mismatch}`
  if resolutions differ.

  ## Examples

      iex> ExH3o.indices_are_neighbors(0x8928308280fffff, 0x8928308280bffff)
      {:ok, true}

      iex> ExH3o.indices_are_neighbors(0x8928308280fffff, 0x8928308281bffff)
      {:ok, false}

      iex> ExH3o.indices_are_neighbors(0, 0x8928308280fffff)
      {:error, :invalid_index}
  """
  @spec indices_are_neighbors(non_neg_integer(), non_neg_integer()) ::
          {:ok, boolean()} | {:error, :invalid_index | :resolution_mismatch}
  defdelegate indices_are_neighbors(a, b), to: ExH3o.Native

  @doc """
  Returns the grid distance between two H3 cell indices.

  The grid distance is the minimum number of cell hops to get from one cell
  to the other. Returns a signed integer faithfully representing h3o's `i32`.

  ## Examples

      iex> ExH3o.grid_distance(0x8928308280fffff, 0x8928308280fffff)
      {:ok, 0}

      iex> ExH3o.grid_distance(0x8928308280fffff, 0x8928308280bffff)
      {:ok, 1}

      iex> ExH3o.grid_distance(0, 0x8928308280fffff)
      {:error, :invalid_index}
  """
  @spec grid_distance(non_neg_integer(), non_neg_integer()) ::
          {:ok, integer()} | {:error, :invalid_index | :local_ij_error}
  defdelegate grid_distance(a, b), to: ExH3o.Native

  @doc """
  Returns the directed edge index from `origin` to `destination`.

  Both cells must be neighbors. Returns `{:error, :not_neighbors}` if they
  are not adjacent.

  ## Examples

      iex> {:ok, edge} = ExH3o.get_unidirectional_edge(0x8928308280fffff, 0x8928308280bffff)
      iex> edge > 0
      true

      iex> ExH3o.get_unidirectional_edge(0x8928308280fffff, 0x8928308281bffff)
      {:error, :not_neighbors}

      iex> ExH3o.get_unidirectional_edge(0, 0x8928308280fffff)
      {:error, :invalid_index}
  """
  @spec get_unidirectional_edge(non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_index | :not_neighbors}
  defdelegate get_unidirectional_edge(origin, destination), to: ExH3o.Native
end
