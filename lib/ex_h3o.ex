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
  Converts a valid H3 cell index to its lowercase hex string representation.

  ## Examples

      iex> ExH3o.to_string(0x8928308280fffff)
      {:ok, "8928308280fffff"}

      iex> ExH3o.to_string(0)
      {:error, :invalid_index}
  """
  @spec to_string(non_neg_integer()) :: {:ok, String.t()} | {:error, :invalid_index}
  defdelegate to_string(cell), to: ExH3o.Native

  @doc """
  Parses a hex string into an H3 cell index.

  The string must be valid hexadecimal and represent a valid H3 cell index.

  ## Examples

      iex> ExH3o.from_string("8928308280fffff")
      {:ok, 0x8928308280fffff}

      iex> ExH3o.from_string("not_hex")
      {:error, :invalid_string}

      iex> ExH3o.from_string("0000000000000000")
      {:error, :invalid_string}
  """
  @spec from_string(String.t()) :: {:ok, non_neg_integer()} | {:error, :invalid_string}
  defdelegate from_string(hex), to: ExH3o.Native

  @doc """
  Returns the parent cell at the given resolution.

  The target resolution must be coarser than (less than) or equal to the
  cell's current resolution. When the target resolution equals the cell's
  resolution, the cell itself is returned (identity).

  ## Examples

      iex> {:ok, parent} = ExH3o.parent(0x8928308280fffff, 8)
      iex> {:ok, 8} = ExH3o.get_resolution(parent)
      {:ok, 8}

      iex> ExH3o.parent(0x8928308280fffff, 10)
      {:error, :invalid_resolution}

      iex> ExH3o.parent(0, 5)
      {:error, :invalid_index}
  """
  @spec parent(non_neg_integer(), 0..15) ::
          {:ok, non_neg_integer()} | {:error, :invalid_index | :invalid_resolution}
  defdelegate parent(cell, resolution), to: ExH3o.Native

  @doc """
  Returns whether two H3 cell indices are neighbors (share an edge).

  Both cells must be at the same resolution. If they have different
  resolutions, returns `{:error, :resolution_mismatch}`.

  ## Examples

      iex> ExH3o.indices_are_neighbors(0x8928308280fffff, 0x8928308280bffff)
      {:ok, true}

      iex> ExH3o.indices_are_neighbors(0, 0x8928308280fffff)
      {:error, :invalid_index}
  """
  @spec indices_are_neighbors(non_neg_integer(), non_neg_integer()) ::
          {:ok, boolean()} | {:error, :invalid_index | :resolution_mismatch}
  defdelegate indices_are_neighbors(a, b), to: ExH3o.Native

  @doc """
  Returns the grid distance between two H3 cell indices.

  Grid distance is the minimum number of cell hops needed to get from
  one cell to the other. Returns a signed integer (faithfully representing
  h3o's `i32` return type).

  May fail for cells that are very far apart or across pentagons.

  ## Examples

      iex> ExH3o.grid_distance(0x8928308280fffff, 0x8928308280fffff)
      {:ok, 0}

      iex> ExH3o.grid_distance(0, 0x8928308280fffff)
      {:error, :invalid_index}
  """
  @spec grid_distance(non_neg_integer(), non_neg_integer()) ::
          {:ok, integer()} | {:error, :invalid_index | :local_ij_error}
  defdelegate grid_distance(a, b), to: ExH3o.Native

  @doc """
  Returns the directed edge index from origin to destination.

  Both cells must be neighbors (share an edge). If they are not neighbors,
  returns `{:error, :not_neighbors}`.

  ## Examples

      iex> {:ok, edge} = ExH3o.get_unidirectional_edge(0x8928308280fffff, 0x8928308280bffff)
      iex> edge > 0
      true

      iex> ExH3o.get_unidirectional_edge(0, 0x8928308280fffff)
      {:error, :invalid_index}
  """
  @spec get_unidirectional_edge(non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_index | :not_neighbors}
  defdelegate get_unidirectional_edge(origin, destination), to: ExH3o.Native

  @doc """
  Returns the children cells at the given resolution.

  The target resolution must be finer than (greater than) or equal to the
  cell's current resolution. At the same resolution, returns a list
  containing only the cell itself. Hexagons produce 7 children at the
  next resolution; pentagons produce 6.

  The NIF returns a packed binary of u64 cell indices for efficiency —
  this function decodes it into a list of integers.

  ## Examples

      iex> {:ok, children} = ExH3o.children(0x8928308280fffff, 10)
      iex> length(children)
      7

      iex> ExH3o.children(0, 5)
      {:error, :invalid_index}

      iex> ExH3o.children(0x8928308280fffff, 8)
      {:error, :invalid_resolution}
  """
  @spec children(non_neg_integer(), 0..15) ::
          {:ok, [non_neg_integer()]} | {:error, :invalid_index | :invalid_resolution}
  def children(cell, resolution) do
    case ExH3o.Native.children(cell, resolution) do
      {:ok, packed} when is_binary(packed) ->
        {:ok, for(<<index::native-unsigned-64 <- packed>>, do: index)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the cells within k-ring distance of the given cell.

  k-ring (grid disk) returns all cells whose grid distance is at most `k`
  from the origin cell. At k=0, returns only the origin. Cell count follows
  the formula 3k² + 3k + 1 for hexagonal cells.

  The NIF returns a packed binary of u64 cell indices for efficiency —
  this function decodes it into a list of integers.

  ## Examples

      iex> {:ok, [cell]} = ExH3o.k_ring(0x8928308280fffff, 0)
      iex> cell == 0x8928308280fffff
      true

      iex> {:ok, cells} = ExH3o.k_ring(0x8928308280fffff, 1)
      iex> length(cells)
      7

      iex> ExH3o.k_ring(0, 1)
      {:error, :invalid_index}
  """
  @spec k_ring(non_neg_integer(), non_neg_integer()) ::
          {:ok, [non_neg_integer()]} | {:error, :invalid_index}
  def k_ring(cell, k) do
    case ExH3o.Native.k_ring(cell, k) do
      {:ok, packed} when is_binary(packed) ->
        {:ok, for(<<index::native-unsigned-64 <- packed>>, do: index)}

      {:error, _} = error ->
        error
    end
  end
end
