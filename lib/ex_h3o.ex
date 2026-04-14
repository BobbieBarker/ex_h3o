defmodule ExH3o do
  @moduledoc """
  Elixir bindings for [h3o](https://github.com/HydroniumLabs/h3o), a
  Rust implementation of Uber's [H3](https://h3geo.org/docs/)
  geospatial indexing system.

  H3 is a hierarchical hexagonal grid that maps geographic coordinates
  onto hexagonal cells at 16 resolutions. It is used for spatial
  indexing, aggregation, and analysis of location data.

  ## Usage

      # Convert a coordinate to an H3 cell at resolution 9
      cell = ExH3o.from_geo({37.7749, -122.4194}, 9)
      # => 617_700_169_957_507_071

      # Round-trip back to coordinates
      ExH3o.to_geo(cell)
      # => {37.77492, -122.41946}

      # Grid queries
      ExH3o.k_ring(cell, 2)    # all cells within distance 2
      ExH3o.children(cell, 11) # child cells two resolutions deeper
      ExH3o.parent(cell, 7)    # parent cell two resolutions coarser

      # Polygon fill
      ExH3o.polyfill([{37.77, -122.42}, {37.77, -122.41}, {37.78, -122.41}], 9)
  """

  import Bitwise, only: [bor: 2, bsl: 2]

  @typedoc "A 64-bit H3 cell index."
  @type cell :: non_neg_integer()

  @typedoc "An H3 resolution, 0 (coarsest) through 15 (finest)."
  @type resolution :: 0..15

  @typedoc "A geographic coordinate, `{latitude, longitude}` in degrees."
  @type coord :: {float(), float()}

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

  # =========================================================================
  # Pure Elixir: formulas and constants (no NIF roundtrip)
  # =========================================================================

  @doc group: "Pure Elixir"
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

  @doc group: "Pure Elixir"
  @doc """
  Returns the total number of unique H3 indexes at the given resolution.

  The formula is `2 + 120 × 7^resolution`.

  ## Raises

  - `FunctionClauseError` if `resolution` is not an integer in 0..15.

  ## Examples

      iex> ExH3o.num_hexagons(0)
      122

      iex> ExH3o.num_hexagons(15)
      569_707_381_193_162
  """
  @spec num_hexagons(resolution()) :: non_neg_integer()
  def num_hexagons(resolution) when is_integer(resolution) and resolution in 0..15 do
    2 + 120 * Integer.pow(7, resolution)
  end

  @doc group: "Pure Elixir"
  @doc """
  Returns the average hexagon edge length in kilometers at the given resolution.

  Excludes pentagons.

  ## Raises

  - `FunctionClauseError` if `resolution` is not an integer in 0..15.

  ## Examples

      iex> length = ExH3o.edge_length_kilometers(0)
      iex> length > 1000
      true
  """
  @spec edge_length_kilometers(resolution()) :: float()
  def edge_length_kilometers(resolution) when is_integer(resolution) and resolution in 0..15 do
    elem(@edge_length_km, resolution)
  end

  @doc group: "Pure Elixir"
  @doc """
  Returns the average hexagon edge length in meters at the given resolution.

  Excludes pentagons.

  ## Raises

  - `FunctionClauseError` if `resolution` is not an integer in 0..15.

  ## Examples

      iex> length = ExH3o.edge_length_meters(0)
      iex> length > 1_000_000
      true
  """
  @spec edge_length_meters(resolution()) :: float()
  def edge_length_meters(resolution) when is_integer(resolution) and resolution in 0..15 do
    elem(@edge_length_m, resolution)
  end

  @doc group: "Pure Elixir"
  @doc """
  Returns the average hexagon area in square kilometers at the given resolution.

  Excludes pentagons.

  ## Raises

  - `FunctionClauseError` if `resolution` is not an integer in 0..15.

  ## Examples

      iex> area = ExH3o.hex_area_km2(0)
      iex> area > 4_000_000
      true
  """
  @spec hex_area_km2(resolution()) :: float()
  def hex_area_km2(resolution) when is_integer(resolution) and resolution in 0..15 do
    elem(@hex_area_km2, resolution)
  end

  @doc group: "Pure Elixir"
  @doc """
  Returns the average hexagon area in square meters at the given resolution.

  Excludes pentagons.

  ## Raises

  - `FunctionClauseError` if `resolution` is not an integer in 0..15.

  ## Examples

      iex> area = ExH3o.hex_area_m2(0)
      iex> area > 4.0e12
      true
  """
  @spec hex_area_m2(resolution()) :: float()
  def hex_area_m2(resolution) when is_integer(resolution) and resolution in 0..15 do
    elem(@hex_area_m2, resolution)
  end

  @doc group: "Pure Elixir"
  @doc """
  Returns all 122 resolution 0 (base cell) H3 indexes.

  These are the coarsest cells in the H3 system and are the ancestors
  of all other cells.

  ## Examples

      iex> cells = ExH3o.get_res0_indexes()
      iex> length(cells)
      122
  """
  @spec get_res0_indexes() :: [cell()]
  def get_res0_indexes do
    @res0_indexes
  end

  # =========================================================================
  # Single-cell inspection (NIF)
  # =========================================================================

  @doc group: "Cell inspection"
  @doc """
  Returns whether `cell` is a valid H3 cell index.

  Accepts a non-negative integer representing an H3 cell index and
  returns `true` if it is valid, `false` otherwise. Raises
  `ArgumentError` on non-integer input.

  ## Examples

      iex> ExH3o.is_valid(0x8928308280fffff)
      true

      iex> ExH3o.is_valid(0)
      false
  """
  @spec is_valid(cell()) :: boolean()
  defdelegate is_valid(cell), to: ExH3o.Native

  @doc group: "Cell inspection"
  @doc """
  Returns the resolution (0-15) of the given H3 cell index.

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index.

  ## Examples

      iex> ExH3o.get_resolution(0x8928308280fffff)
      9
  """
  @spec get_resolution(cell()) :: resolution()
  defdelegate get_resolution(cell), to: ExH3o.Native

  @doc group: "Cell inspection"
  @doc """
  Returns the base cell number (0-121) of the given H3 cell index.

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index.

  ## Examples

      iex> base = ExH3o.get_base_cell(0x8928308280fffff)
      iex> base in 0..121
      true
  """
  @spec get_base_cell(cell()) :: non_neg_integer()
  defdelegate get_base_cell(cell), to: ExH3o.Native

  @doc group: "Cell inspection"
  @doc """
  Returns whether the given H3 cell index is a pentagon.

  H3 has 12 pentagons at each resolution (one per icosahedron vertex).

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index.

  ## Examples

      iex> ExH3o.is_pentagon(0x8928308280fffff)
      false

      iex> ExH3o.is_pentagon(0x8009fffffffffff)
      true
  """
  @spec is_pentagon(cell()) :: boolean()
  defdelegate is_pentagon(cell), to: ExH3o.Native

  @doc group: "Cell inspection"
  @doc """
  Returns whether the given H3 cell index is Class III.

  Class III cells occur at odd resolutions. Class II cells occur at
  even resolutions.

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index.

  ## Examples

      iex> ExH3o.is_class3(0x8928308280fffff)
      true

      iex> ExH3o.is_class3(0x8009fffffffffff)
      false
  """
  @spec is_class3(cell()) :: boolean()
  defdelegate is_class3(cell), to: ExH3o.Native

  # =========================================================================
  # String conversion (NIF)
  # =========================================================================

  @doc group: "String conversion"
  @doc """
  Converts a valid H3 cell index to its lowercase hex string representation.

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index.

  ## Examples

      iex> ExH3o.to_string(0x8928308280fffff)
      "8928308280fffff"
  """
  @spec to_string(cell()) :: String.t()
  defdelegate to_string(cell), to: ExH3o.Native

  @doc group: "String conversion"
  @doc """
  Parses a hex string into an H3 cell index.

  The string must be valid hexadecimal and represent a valid H3 cell index.
  An optional `0x` prefix is accepted and stripped.

  ## Raises

  - `ArgumentError` if the string is not valid hex, or if the parsed
    value is not a valid H3 cell index.

  ## Examples

      iex> ExH3o.from_string("8928308280fffff")
      0x8928308280fffff
  """
  @spec from_string(String.t()) :: cell()
  defdelegate from_string(hex), to: ExH3o.Native

  # =========================================================================
  # Hierarchy (NIF)
  # =========================================================================

  @doc group: "Hierarchy"
  @doc """
  Returns the parent cell at the given resolution.

  The target resolution must be coarser than (less than) or equal to
  the cell's current resolution. When the target resolution equals the
  cell's resolution, the cell itself is returned (identity).

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index, if `resolution`
    is finer than the cell's own resolution (the parent doesn't
    exist), or if `resolution` is not in 0..15.

  ## Examples

      iex> parent = ExH3o.parent(0x8928308280fffff, 8)
      iex> ExH3o.get_resolution(parent)
      8
  """
  @spec parent(cell(), resolution()) :: cell()
  defdelegate parent(cell, resolution), to: ExH3o.Native

  @doc group: "Hierarchy"
  @doc """
  Returns the children cells at the given resolution.

  The target resolution must be finer than (greater than) or equal to
  the cell's current resolution. At the same resolution, returns a
  list containing only the cell itself. Hexagons produce 7 children at
  the next resolution; pentagons produce 6.

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index, if `resolution`
    is coarser than the cell's own resolution, or if `resolution` is
    not in 0..15.

  ## Examples

      iex> children = ExH3o.children(0x8928308280fffff, 10)
      iex> length(children)
      7
  """
  @spec children(cell(), resolution()) :: [cell()]
  defdelegate children(cell, resolution), to: ExH3o.Native

  # =========================================================================
  # Neighbors / distance / edges (NIF)
  # =========================================================================

  @doc group: "Neighbors & distance"
  @doc """
  Returns whether two H3 cell indices are neighbors (share an edge).

  Both cells must be at the same resolution.

  ## Raises

  - `ArgumentError` if either cell is not a valid H3 index, or if the
    two cells have different resolutions.

  ## Examples

      iex> ExH3o.indices_are_neighbors(0x8928308280fffff, 0x8928308280bffff)
      true
  """
  @spec indices_are_neighbors(cell(), cell()) :: boolean()
  defdelegate indices_are_neighbors(a, b), to: ExH3o.Native

  @doc group: "Neighbors & distance"
  @doc """
  Returns the grid distance between two H3 cell indices.

  Grid distance is the minimum number of cell hops needed to get from
  one cell to the other.

  ## Raises

  - `ArgumentError` if either cell is not a valid H3 index, or if the
    distance cannot be computed (cells very far apart or across
    pentagons).

  ## Examples

      iex> ExH3o.grid_distance(0x8928308280fffff, 0x8928308280fffff)
      0
  """
  @spec grid_distance(cell(), cell()) :: integer()
  defdelegate grid_distance(a, b), to: ExH3o.Native

  @doc group: "Neighbors & distance"
  @doc """
  Returns the directed edge index from origin to destination.

  Both cells must be neighbors (share an edge).

  ## Raises

  - `ArgumentError` if either cell is not a valid H3 index, or if the
    two cells are not neighbors.

  ## Examples

      iex> edge = ExH3o.get_unidirectional_edge(0x8928308280fffff, 0x8928308280bffff)
      iex> edge > 0
      true
  """
  @spec get_unidirectional_edge(cell(), cell()) :: cell()
  defdelegate get_unidirectional_edge(origin, destination), to: ExH3o.Native

  # =========================================================================
  # Grid disk family (NIF, DirtyCpu)
  # =========================================================================

  @doc group: "Grid disk"
  @doc """
  Returns the cells within k-ring distance of the given cell.

  k-ring (grid disk) returns all cells whose grid distance is at most
  `k` from the origin cell. At k=0, returns only the origin. Cell
  count follows the formula 3k² + 3k + 1 for hexagonal cells.

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index.

  ## Examples

      iex> [cell] = ExH3o.k_ring(0x8928308280fffff, 0)
      iex> cell == 0x8928308280fffff
      true

      iex> cells = ExH3o.k_ring(0x8928308280fffff, 1)
      iex> length(cells)
      7
  """
  @spec k_ring(cell(), non_neg_integer()) :: [cell()]
  defdelegate k_ring(cell, k), to: ExH3o.Native

  @doc group: "Grid disk"
  @doc """
  Returns `{cell, distance}` tuples for each cell within k-ring distance
  of the given cell.

  The `distance` is the grid distance from the origin (0 for the origin
  itself, 1 for immediate neighbors, etc).

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index.

  ## Examples

      iex> pairs = ExH3o.k_ring_distances(0x8928308280fffff, 1)
      iex> length(pairs)
      7
  """
  @spec k_ring_distances(cell(), non_neg_integer()) :: [{cell(), non_neg_integer()}]
  defdelegate k_ring_distances(cell, k), to: ExH3o.Native

  # =========================================================================
  # Geo <-> cell (NIF)
  # =========================================================================

  @doc group: "Geo coordinates"
  @doc """
  Converts geographic coordinates to an H3 cell index at the given resolution.

  Takes a `{lat, lng}` tuple in degrees and a resolution (0-15).
  Returns the H3 cell index containing the given coordinates.

  Accepts integer coordinates as well as floats. The Elixir wrapper
  coerces them to floats before calling the NIF.

  ## Raises

  - `ArgumentError` if the coordinate is out of range (lat ∉ [-90, 90]
    or lng ∉ [-180, 180]) or non-finite.
  - `FunctionClauseError` if `lat` or `lng` is not a number, or if
    `resolution` is not in 0..15.

  ## Examples

      iex> cell = ExH3o.from_geo({37.7749, -122.4194}, 9)
      iex> ExH3o.is_valid(cell)
      true
  """
  @spec from_geo(coord(), resolution()) :: cell()
  def from_geo({lat, lng}, resolution)
      when is_number(lat) and is_number(lng) and is_integer(resolution) and resolution in 0..15 do
    ExH3o.Native.from_geo(lat / 1, lng / 1, resolution)
  end

  @doc group: "Geo coordinates"
  @doc """
  Returns the center coordinates of the given H3 cell index.

  Returns `{lat, lng}` in degrees where lat is in `[-90, 90]` and lng
  is in `[-180, 180]`.

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index.

  ## Examples

      iex> {lat, lng} = ExH3o.to_geo(0x8928308280fffff)
      iex> lat >= -90.0 and lat <= 90.0 and lng >= -180.0 and lng <= 180.0
      true
  """
  @spec to_geo(cell()) :: coord()
  defdelegate to_geo(cell), to: ExH3o.Native

  @doc group: "Geo coordinates"
  @doc """
  Returns the boundary vertices of the given H3 cell index.

  Returns a list of `{lat, lng}` tuples in degrees. Hexagons have 6
  vertices, pentagons have 5.

  ## Raises

  - `ArgumentError` if `cell` is not a valid H3 index.

  ## Examples

      iex> vertices = ExH3o.to_geo_boundary(0x8928308280fffff)
      iex> length(vertices)
      6
  """
  @spec to_geo_boundary(cell()) :: [coord(), ...]
  defdelegate to_geo_boundary(cell), to: ExH3o.Native

  # =========================================================================
  # Compact / uncompact (NIF, DirtyCpu)
  # =========================================================================

  @doc group: "Set operations"
  @doc """
  Compacts a set of H3 cell indices by replacing complete child sets
  with their parent cell, applied recursively.

  All input cells must be at the same resolution and unique. Returns
  the minimal set of cells that covers the same area.

  ## Raises

  - `ArgumentError` if the input contains invalid cells, cells at
    different resolutions, or duplicate cells.

  ## Examples

      iex> children = ExH3o.children(0x8928308280fffff, 10)
      iex> ExH3o.compact(children)
      [0x8928308280fffff]

      iex> ExH3o.compact([])
      []
  """
  @spec compact([cell()]) :: [cell()]
  def compact(cells) when is_list(cells) do
    cells
    |> pack_cells()
    |> ExH3o.Native.compact()
  end

  @doc group: "Set operations"
  @doc """
  Expands a compacted set of H3 cell indices to the given resolution.

  Each cell in the input is dissolved into its descendants at the
  target resolution. The target resolution must be equal to or finer
  than every cell's resolution. When a cell is already at the target
  resolution, it passes through unchanged.

  This is the inverse of `compact/1`.

  ## Raises

  - `ArgumentError` if the input contains invalid cells, or if
    `resolution` is coarser than any input cell's own resolution.
  - `FunctionClauseError` if `resolution` is not in 0..15.

  ## Examples

      iex> children = ExH3o.children(0x8928308280fffff, 10)
      iex> compacted = ExH3o.compact(children)
      iex> uncompacted = ExH3o.uncompact(compacted, 10)
      iex> Enum.sort(uncompacted) == Enum.sort(children)
      true

      iex> ExH3o.uncompact([0x8928308280fffff], 9)
      [0x8928308280fffff]

      iex> ExH3o.uncompact([], 5)
      []
  """
  @spec uncompact([cell()], resolution()) :: [cell()]
  def uncompact(cells, resolution)
      when is_list(cells) and is_integer(resolution) and resolution in 0..15 do
    cells
    |> pack_cells()
    |> ExH3o.Native.uncompact(resolution)
  end

  # =========================================================================
  # Polyfill (NIF, DirtyCpu)
  # =========================================================================

  @doc group: "Polygon fill"
  @doc """
  Returns the H3 cell indices whose centroids fall within the given
  polygon at the specified resolution.

  The polygon is specified as a list of `{lat, lng}` vertex tuples in
  degrees. At least 3 distinct vertices are required. Uses
  `ContainsCentroid` containment mode (cells whose centroids fall
  inside the polygon are included).

  ## Raises

  - `ArgumentError` if fewer than 3 vertices are provided, if any
    vertex is not a `{float, float}` tuple, or if the polygon is
    otherwise invalid.
  - `FunctionClauseError` if `vertices` is not a list or `resolution`
    is not in 0..15.

  ## Examples

      iex> polygon = [{37.77, -122.42}, {37.77, -122.41}, {37.78, -122.41}, {37.78, -122.42}]
      iex> cells = ExH3o.polyfill(polygon, 9)
      iex> length(cells) > 0
      true
  """
  @spec polyfill([coord()], resolution()) :: [cell()]
  def polyfill(vertices, resolution)
      when is_list(vertices) and is_integer(resolution) and resolution in 0..15 do
    vertices
    |> pack_coords()
    |> ExH3o.Native.polyfill(resolution)
  end

  # =========================================================================
  # Internal helpers
  # =========================================================================

  # Packs a list of u64 cells into a native-endian binary for input to
  # the compact/uncompact NIFs. The C NIF reads the bytes directly via
  # enif_inspect_binary and passes (pointer, count) to Rust.
  @spec pack_cells([cell()]) :: binary()
  defp pack_cells(cells) do
    for cell <- cells, into: <<>>, do: <<cell::native-unsigned-64>>
  end

  # Packs a list of `{lat, lng}` float tuples into a native-endian
  # `<<lat::float-64, lng::float-64, ...>>` binary for input to the
  # polyfill NIF. The C side passes this directly to Rust via a raw
  # pointer + vertex count, eliminating the per-vertex list walk that
  # would otherwise happen inside the dirty NIF body.
  #
  # Integer coordinates are coerced to floats so callers can pass
  # `{37, -122}` without first calling `lat / 1`. Non-numeric input
  # raises `ArithmeticError` from the multiplication, which propagates
  # out as the API's documented "raises on bad input" contract.
  @spec pack_coords([coord()]) :: binary()
  defp pack_coords(vertices) do
    for {lat, lng} <- vertices,
        into: <<>>,
        do: <<lat * 1.0::native-float-64, lng * 1.0::native-float-64>>
  end
end
