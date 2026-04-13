defmodule ExH3o do
  @moduledoc """
  Elixir bindings for [h3o](https://github.com/HydroniumLabs/h3o), a Rust
  implementation of the H3 geospatial indexing system.

  Several functions are implemented as pure Elixir (no NIF roundtrip):
  `max_k_ring_size/1`, `num_hexagons/1`, `edge_length_kilometers/1`,
  `edge_length_meters/1`, `hex_area_km2/1`, `hex_area_m2/1`, and
  `get_res0_indexes/0`.

  H3 is a hierarchical hexagonal grid system that maps geographic coordinates
  to hexagonal cells at multiple resolutions (0-15). It is used for spatial
  indexing, analysis, and aggregation of geospatial data.
  """

  import Bitwise, only: [bor: 2, bsl: 2]

  @edge_length_km {1281.256011, 483.0568391, 182.5129565, 68.97922179, 26.07175968, 9.854090990,
                   3.724532667, 1.406475763, 0.531414010, 0.200786148, 0.075863783, 0.028663897,
                   0.010830188, 0.004092010, 0.001546100, 0.000584169}

  @edge_length_m {1_281_256.011, 483_056.8391, 182_512.9565, 68_979.22179, 26_071.75968,
                  9854.090990, 3724.532667, 1406.475763, 531.4140101, 200.7861476, 75.86378287,
                  28.66389748, 10.83018784, 4.092010473, 1.546099657, 0.584168630}

  # credo:disable-for-lines:7 Credo.Check.Readability.LargeNumbers
  @hex_area_km2 {4.357449416078383e6, 6.097884417941332e5, 8.680178039899720e4,
                 1.239343465508816e4, 1.770347654491307e3, 2.529038581819449e2,
                 3.612906216441245e1, 5.161293359717191e0, 7.373275975944177e-1,
                 1.053325134272067e-1, 1.504750190766435e-2, 2.149643129451879e-3,
                 3.070918756316060e-4, 4.387026794728296e-5, 6.267181135324313e-6,
                 8.953115907605790e-7}

  # credo:disable-for-lines:7 Credo.Check.Readability.LargeNumbers
  @hex_area_m2 {4.357449416078390e12, 6.097884417941339e11, 8.680178039899731e10,
                1.239343465508818e10, 1.770347654491309e9, 2.529038581819452e8,
                3.612906216441250e7, 5.161293359717198e6, 7.373275975944188e5,
                1.053325134272069e5, 1.504750190766437e4, 2.149643129451882e3,
                3.070918756316063e2, 4.387026794728301e1, 6.267181135324322e0,
                8.953115907605802e-1}

  @res0_indexes for bc <- 0..121, do: bor(bor(bsl(1, 59), bsl(bc, 45)), 0x1FFFFFFFFFFF)

  @doc """
  Returns the maximum number of cells in a k-ring of size `k`.

  This is a pure computation: `3k² + 3k + 1`.

  ## Examples

      iex> ExH3o.max_k_ring_size(0)
      1

      iex> ExH3o.max_k_ring_size(1)
      7

      iex> ExH3o.max_k_ring_size(2)
      19
  """
  @spec max_k_ring_size(non_neg_integer()) :: non_neg_integer()
  def max_k_ring_size(k) when is_integer(k) and k >= 0 do
    3 * k * k + 3 * k + 1
  end

  @doc """
  Returns the total number of unique H3 indexes at the given resolution.

  The formula is `2 + 120 × 7^resolution`.

  ## Examples

      iex> ExH3o.num_hexagons(0)
      {:ok, 122}

      iex> ExH3o.num_hexagons(15)
      {:ok, 569_707_381_193_162}

      iex> ExH3o.num_hexagons(16)
      {:error, :invalid_resolution}
  """
  @spec num_hexagons(integer()) :: {:ok, non_neg_integer()} | {:error, :invalid_resolution}
  def num_hexagons(resolution) when is_integer(resolution) and resolution in 0..15 do
    {:ok, 2 + 120 * Integer.pow(7, resolution)}
  end

  def num_hexagons(_resolution), do: {:error, :invalid_resolution}

  @doc """
  Returns the average hexagon edge length in kilometers at the given resolution.

  Excludes pentagons.

  ## Examples

      iex> {:ok, length} = ExH3o.edge_length_kilometers(0)
      iex> length > 1000
      true

      iex> ExH3o.edge_length_kilometers(16)
      {:error, :invalid_resolution}
  """
  @spec edge_length_kilometers(integer()) :: {:ok, float()} | {:error, :invalid_resolution}
  def edge_length_kilometers(resolution) when is_integer(resolution) and resolution in 0..15 do
    {:ok, elem(@edge_length_km, resolution)}
  end

  def edge_length_kilometers(_resolution), do: {:error, :invalid_resolution}

  @doc """
  Returns the average hexagon edge length in meters at the given resolution.

  Excludes pentagons.

  ## Examples

      iex> {:ok, length} = ExH3o.edge_length_meters(0)
      iex> length > 1_000_000
      true

      iex> ExH3o.edge_length_meters(16)
      {:error, :invalid_resolution}
  """
  @spec edge_length_meters(integer()) :: {:ok, float()} | {:error, :invalid_resolution}
  def edge_length_meters(resolution) when is_integer(resolution) and resolution in 0..15 do
    {:ok, elem(@edge_length_m, resolution)}
  end

  def edge_length_meters(_resolution), do: {:error, :invalid_resolution}

  @doc """
  Returns the average hexagon area in square kilometers at the given resolution.

  Excludes pentagons.

  ## Examples

      iex> {:ok, area} = ExH3o.hex_area_km2(0)
      iex> area > 4_000_000
      true

      iex> ExH3o.hex_area_km2(16)
      {:error, :invalid_resolution}
  """
  @spec hex_area_km2(integer()) :: {:ok, float()} | {:error, :invalid_resolution}
  def hex_area_km2(resolution) when is_integer(resolution) and resolution in 0..15 do
    {:ok, elem(@hex_area_km2, resolution)}
  end

  def hex_area_km2(_resolution), do: {:error, :invalid_resolution}

  @doc """
  Returns the average hexagon area in square meters at the given resolution.

  Excludes pentagons.

  ## Examples

      iex> {:ok, area} = ExH3o.hex_area_m2(0)
      iex> area > 4.0e12
      true

      iex> ExH3o.hex_area_m2(16)
      {:error, :invalid_resolution}
  """
  @spec hex_area_m2(integer()) :: {:ok, float()} | {:error, :invalid_resolution}
  def hex_area_m2(resolution) when is_integer(resolution) and resolution in 0..15 do
    {:ok, elem(@hex_area_m2, resolution)}
  end

  def hex_area_m2(_resolution), do: {:error, :invalid_resolution}

  @doc """
  Returns all 122 resolution 0 (base cell) H3 indexes.

  These are the coarsest cells in the H3 system and are the
  ancestors of all other cells.

  ## Examples

      iex> {:ok, cells} = ExH3o.get_res0_indexes()
      iex> length(cells)
      122
  """
  @spec get_res0_indexes() :: {:ok, [non_neg_integer()]}
  def get_res0_indexes do
    {:ok, @res0_indexes}
  end

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
