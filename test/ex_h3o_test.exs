defmodule ExH3oTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest ExH3o

  # Known valid H3 cell at resolution 9
  @valid_cell 0x8928308280FFFFF
  # Pentagon cell: base cell 4 at resolution 0
  @pentagon_cell 0x8009FFFFFFFFFFF
  # Invalid cells
  @zero 0
  @max_uint64 0xFFFFFFFFFFFFFFFF
  @garbage 0xDEADBEEF

  describe "is_valid/1" do
    test "returns true for a known valid H3 cell" do
      assert ExH3o.is_valid(@valid_cell)
    end

    test "returns false for zero" do
      refute ExH3o.is_valid(0)
    end

    test "returns false for max uint64" do
      refute ExH3o.is_valid(@max_uint64)
    end

    test "returns false for random garbage value" do
      refute ExH3o.is_valid(@garbage)
    end

    property "always returns a boolean for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        result = ExH3o.is_valid(cell)
        assert is_boolean(result)
      end
    end
  end

  describe "get_resolution/1" do
    test "returns resolution 9 for known cell" do
      assert ExH3o.get_resolution(@valid_cell) == 9
    end

    test "returns resolution 0 for pentagon base cell" do
      assert ExH3o.get_resolution(@pentagon_cell) == 0
    end

    test "returns error for zero" do
      assert_raise ArgumentError, fn -> ExH3o.get_resolution(@zero) end
    end

    test "returns error for max uint64" do
      assert_raise ArgumentError, fn -> ExH3o.get_resolution(@max_uint64) end
    end

    test "returns error for garbage" do
      assert_raise ArgumentError, fn -> ExH3o.get_resolution(@garbage) end
    end

    property "returns 0..15 or raises ArgumentError for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          assert ExH3o.get_resolution(cell) in 0..15
        else
          assert_raise ArgumentError, fn -> ExH3o.get_resolution(cell) end
        end
      end
    end
  end

  describe "get_base_cell/1" do
    test "returns a valid base cell number for known cell" do
      base = ExH3o.get_base_cell(@valid_cell)
      assert base in 0..121
    end

    test "returns a valid base cell for pentagon cell" do
      base = ExH3o.get_base_cell(@pentagon_cell)
      assert base in 0..121
    end

    test "returns error for zero" do
      assert_raise ArgumentError, fn -> ExH3o.get_base_cell(@zero) end
    end

    test "returns error for max uint64" do
      assert_raise ArgumentError, fn -> ExH3o.get_base_cell(@max_uint64) end
    end

    test "returns error for garbage" do
      assert_raise ArgumentError, fn -> ExH3o.get_base_cell(@garbage) end
    end

    property "returns 0..121 or raises ArgumentError for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          assert ExH3o.get_base_cell(cell) in 0..121
        else
          assert_raise ArgumentError, fn -> ExH3o.get_base_cell(cell) end
        end
      end
    end
  end

  describe "is_pentagon/1" do
    test "returns false for a known hexagon" do
      assert ExH3o.is_pentagon(@valid_cell) == false
    end

    test "returns true for a known pentagon" do
      assert ExH3o.is_pentagon(@pentagon_cell) == true
    end

    test "returns error for zero" do
      assert_raise ArgumentError, fn -> ExH3o.is_pentagon(@zero) end
    end

    test "returns error for max uint64" do
      assert_raise ArgumentError, fn -> ExH3o.is_pentagon(@max_uint64) end
    end

    test "returns error for garbage" do
      assert_raise ArgumentError, fn -> ExH3o.is_pentagon(@garbage) end
    end

    property "returns boolean or raises ArgumentError for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          assert is_boolean(ExH3o.is_pentagon(cell))
        else
          assert_raise ArgumentError, fn -> ExH3o.is_pentagon(cell) end
        end
      end
    end
  end

  describe "is_class3/1" do
    test "returns true for odd resolution (res 9)" do
      assert ExH3o.is_class3(@valid_cell) == true
    end

    test "returns false for even resolution (res 0)" do
      assert ExH3o.is_class3(@pentagon_cell) == false
    end

    test "returns error for zero" do
      assert_raise ArgumentError, fn -> ExH3o.is_class3(@zero) end
    end

    test "returns error for max uint64" do
      assert_raise ArgumentError, fn -> ExH3o.is_class3(@max_uint64) end
    end

    test "returns error for garbage" do
      assert_raise ArgumentError, fn -> ExH3o.is_class3(@garbage) end
    end

    property "returns boolean or raises ArgumentError for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          assert is_boolean(ExH3o.is_class3(cell))
        else
          assert_raise ArgumentError, fn -> ExH3o.is_class3(cell) end
        end
      end
    end
  end

  describe "children/2" do
    test "hexagon at next resolution returns 7 children" do
      children = ExH3o.children(@valid_cell, 10)
      assert length(children) == 7

      Enum.each(children, fn child ->
        assert ExH3o.get_resolution(child) == 10
      end)
    end

    test "pentagon at next resolution returns 6 children" do
      children = ExH3o.children(@pentagon_cell, 1)
      assert length(children) == 6

      Enum.each(children, fn child ->
        assert ExH3o.get_resolution(child) == 1
      end)
    end

    test "children count at res+2 is 49 for hexagon" do
      children = ExH3o.children(@valid_cell, 11)
      assert length(children) == 49

      Enum.each(children, fn child ->
        assert ExH3o.get_resolution(child) == 11
      end)
    end

    test "all children are valid H3 cells" do
      children = ExH3o.children(@valid_cell, 10)

      Enum.each(children, fn child ->
        assert ExH3o.is_valid(child)
      end)
    end

    test "children at same resolution returns only self" do
      assert [cell] = ExH3o.children(@valid_cell, 9)
      assert cell == @valid_cell
    end

    test "returns error for coarser resolution" do
      assert_raise ArgumentError, fn -> ExH3o.children(@valid_cell, 8) end
    end

    test "returns error for resolution out of range" do
      assert_raise ArgumentError, fn -> ExH3o.children(@valid_cell, 16) end
    end

    test "returns error for invalid cell index" do
      assert_raise ArgumentError, fn -> ExH3o.children(@zero, 5) end
    end

    test "returns error for garbage cell" do
      assert_raise ArgumentError, fn -> ExH3o.children(@garbage, 5) end
    end

    test "returns error for max uint64 cell" do
      assert_raise ArgumentError, fn -> ExH3o.children(@max_uint64, 5) end
    end

    property "children at next resolution returns list of valid cells" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          res = ExH3o.get_resolution(cell)

          if res < 15 do
            children = ExH3o.children(cell, res + 1)
            assert is_list(children)
            assert length(children) in [6, 7]

            Enum.each(children, fn child ->
              assert ExH3o.get_resolution(child) == res + 1
            end)
          end
        end
      end
    end

    property "returns a value or raises ArgumentError for any inputs" do
      check all(
              cell <- non_negative_integer(),
              res <- integer(0..15)
            ) do
        if ExH3o.is_valid(cell) and res >= ExH3o.get_resolution(cell) do
          children = ExH3o.children(cell, res)
          assert is_list(children)
          Enum.each(children, fn child -> assert is_integer(child) and child > 0 end)
        else
          assert_raise ArgumentError, fn -> ExH3o.children(cell, res) end
        end
      end
    end
  end

  describe "parent/2" do
    test "returns parent at coarser resolution" do
      parent_cell = ExH3o.parent(@valid_cell, 8)
      assert ExH3o.get_resolution(parent_cell) == 8
    end

    test "identity: parent at same resolution returns self" do
      assert ExH3o.parent(@valid_cell, 9) == @valid_cell
    end

    test "chain: transitive parent lookup" do
      parent_8 = ExH3o.parent(@valid_cell, 8)
      parent_7_via_8 = ExH3o.parent(parent_8, 7)
      parent_7_direct = ExH3o.parent(@valid_cell, 7)
      assert parent_7_via_8 == parent_7_direct
    end

    test "returns error for finer resolution than cell" do
      assert_raise ArgumentError, fn -> ExH3o.parent(@valid_cell, 10) end
    end

    test "identity: res 0 cell at resolution 0 returns self" do
      assert ExH3o.parent(@pentagon_cell, 0) == @pentagon_cell
    end

    test "returns error for invalid cell index" do
      assert_raise ArgumentError, fn -> ExH3o.parent(@zero, 5) end
    end

    test "returns error for resolution out of range" do
      assert_raise ArgumentError, fn -> ExH3o.parent(@valid_cell, 16) end
    end

    test "returns error for garbage cell" do
      assert_raise ArgumentError, fn -> ExH3o.parent(@garbage, 5) end
    end

    property "parent at coarser resolution has the target resolution" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          res = ExH3o.get_resolution(cell)

          if res > 0 do
            parent = ExH3o.parent(cell, res - 1)
            assert ExH3o.get_resolution(parent) == res - 1
          end
        end
      end
    end

    property "returns a value or raises ArgumentError for any inputs" do
      check all(
              cell <- non_negative_integer(),
              res <- integer(0..15)
            ) do
        if ExH3o.is_valid(cell) and res <= ExH3o.get_resolution(cell) do
          parent = ExH3o.parent(cell, res)
          assert is_integer(parent) and parent > 0
        else
          assert_raise ArgumentError, fn -> ExH3o.parent(cell, res) end
        end
      end
    end
  end

  describe "to_string/1" do
    test "converts valid cell to lowercase hex string" do
      assert ExH3o.to_string(@valid_cell) == "8928308280fffff"
    end

    test "converts pentagon cell to lowercase hex string" do
      assert ExH3o.to_string(@pentagon_cell) == "8009fffffffffff"
    end

    test "returns error for zero (invalid index)" do
      assert_raise ArgumentError, fn -> ExH3o.to_string(@zero) end
    end

    test "returns error for max uint64" do
      assert_raise ArgumentError, fn -> ExH3o.to_string(@max_uint64) end
    end

    test "returns error for garbage value" do
      assert_raise ArgumentError, fn -> ExH3o.to_string(@garbage) end
    end

    property "returns hex string or raises ArgumentError for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          hex = ExH3o.to_string(cell)
          assert is_binary(hex)
          assert Regex.match?(~r/\A[0-9a-f]+\z/, hex)
        else
          assert_raise ArgumentError, fn -> ExH3o.to_string(cell) end
        end
      end
    end
  end

  describe "max_k_ring_size/1" do
    test "k=0 returns 1" do
      assert ExH3o.max_k_ring_size(0) == 1
    end

    test "k=1 returns 7" do
      assert ExH3o.max_k_ring_size(1) == 7
    end

    test "k=2 returns 19" do
      assert ExH3o.max_k_ring_size(2) == 19
    end

    test "k=3 returns 37" do
      assert ExH3o.max_k_ring_size(3) == 37
    end

    test "matches formula 3k² + 3k + 1 for k=0..100" do
      for k <- 0..100 do
        expected = 3 * k * k + 3 * k + 1
        assert ExH3o.max_k_ring_size(k) == expected, "failed for k=#{k}"
      end
    end
  end

  describe "from_string/1" do
    test "parses valid hex string to cell index" do
      assert ExH3o.from_string("8928308280fffff") == @valid_cell
    end

    test "parses pentagon cell hex string" do
      assert ExH3o.from_string("8009fffffffffff") == @pentagon_cell
    end

    test "returns error for non-hex string" do
      assert_raise ArgumentError, fn -> ExH3o.from_string("not_hex") end
    end

    test "returns error for empty string" do
      assert_raise ArgumentError, fn -> ExH3o.from_string("") end
    end

    test "returns error for valid hex but invalid H3 index" do
      assert_raise ArgumentError, fn -> ExH3o.from_string("0000000000000000") end
    end

    property "roundtrip: to_string then from_string returns original cell" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          hex = ExH3o.to_string(cell)
          assert ExH3o.from_string(hex) == cell
        end
      end
    end

    property "roundtrip: from_string then to_string returns original hex (lowercase)" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          hex = ExH3o.to_string(cell)
          assert ExH3o.to_string(ExH3o.from_string(hex)) == hex
        end
      end
    end
  end

  describe "num_hexagons/1" do
    @num_hexagons_by_res %{
      0 => 122,
      1 => 842,
      2 => 5882,
      3 => 41_162,
      4 => 288_122,
      5 => 2_016_842,
      6 => 14_117_882,
      7 => 98_825_162,
      8 => 691_776_122,
      9 => 4_842_432_842,
      10 => 33_897_029_882,
      11 => 237_279_209_162,
      12 => 1_660_954_464_122,
      13 => 11_626_681_248_842,
      14 => 81_386_768_741_882,
      15 => 569_707_381_193_162
    }

    test "returns correct count for all 16 resolutions" do
      for {res, expected} <- @num_hexagons_by_res do
        assert ExH3o.num_hexagons(res) == expected, "failed for res=#{res}"
      end
    end

    test "returns error for resolution -1" do
      assert_raise FunctionClauseError, fn -> ExH3o.num_hexagons(-1) end
    end

    test "returns error for resolution 16" do
      assert_raise FunctionClauseError, fn -> ExH3o.num_hexagons(16) end
    end
  end

  describe "edge_length_kilometers/1" do
    test "resolution 0 is approximately 1281 km" do
      length = ExH3o.edge_length_kilometers(0)
      assert_in_delta length, 1281.256011, 0.001
    end

    test "resolution 15 is sub-meter" do
      length = ExH3o.edge_length_kilometers(15)
      assert length < 0.001
    end

    test "returns error for invalid resolution" do
      assert_raise FunctionClauseError, fn -> ExH3o.edge_length_kilometers(-1) end
      assert_raise FunctionClauseError, fn -> ExH3o.edge_length_kilometers(16) end
    end

    test "lengths decrease monotonically with resolution" do
      lengths =
        for res <- 0..15 do
          ExH3o.edge_length_kilometers(res)
        end

      for [a, b] <- Enum.chunk_every(lengths, 2, 1, :discard) do
        assert a > b
      end
    end
  end

  describe "edge_length_meters/1" do
    test "resolution 0 is approximately 1,281,256 m" do
      length = ExH3o.edge_length_meters(0)
      assert_in_delta length, 1_281_256.011, 0.01
    end

    test "values are 1000x the km values" do
      for res <- 0..15 do
        km = ExH3o.edge_length_kilometers(res)
        m = ExH3o.edge_length_meters(res)
        assert_in_delta m, km * 1000, 0.01, "failed for res=#{res}"
      end
    end

    test "returns error for invalid resolution" do
      assert_raise FunctionClauseError, fn -> ExH3o.edge_length_meters(-1) end
      assert_raise FunctionClauseError, fn -> ExH3o.edge_length_meters(16) end
    end
  end

  describe "hex_area_km2/1" do
    test "resolution 0 is approximately 4.36 million km²" do
      area = ExH3o.hex_area_km2(0)
      assert_in_delta area, 4_357_449.416, 0.001
    end

    test "resolution 15 is sub-square-meter" do
      area = ExH3o.hex_area_km2(15)
      assert area < 0.000001
    end

    test "returns error for invalid resolution" do
      assert_raise FunctionClauseError, fn -> ExH3o.hex_area_km2(-1) end
      assert_raise FunctionClauseError, fn -> ExH3o.hex_area_km2(16) end
    end

    test "areas decrease monotonically with resolution" do
      areas =
        for res <- 0..15 do
          ExH3o.hex_area_km2(res)
        end

      for [a, b] <- Enum.chunk_every(areas, 2, 1, :discard) do
        assert a > b
      end
    end
  end

  describe "hex_area_m2/1" do
    test "resolution 0 is approximately 4.36 trillion m²" do
      area = ExH3o.hex_area_m2(0)
      assert_in_delta area, 4_357_449_416_078.39, 0.1
    end

    test "values are 1_000_000x the km² values" do
      for res <- 0..15 do
        km2 = ExH3o.hex_area_km2(res)
        m2 = ExH3o.hex_area_m2(res)
        assert_in_delta m2, km2 * 1_000_000, 0.1, "failed for res=#{res}"
      end
    end

    test "returns error for invalid resolution" do
      assert_raise FunctionClauseError, fn -> ExH3o.hex_area_m2(-1) end
      assert_raise FunctionClauseError, fn -> ExH3o.hex_area_m2(16) end
    end
  end

  describe "get_res0_indexes/0" do
    test "returns exactly 122 cells" do
      cells = ExH3o.get_res0_indexes()
      assert length(cells) == 122
    end

    test "all cells are valid H3 indices" do
      cells = ExH3o.get_res0_indexes()

      Enum.each(cells, fn cell ->
        assert ExH3o.is_valid(cell), "cell #{Integer.to_string(cell, 16)} is not valid"
      end)
    end

    test "all cells are at resolution 0" do
      cells = ExH3o.get_res0_indexes()

      Enum.each(cells, fn cell ->
        assert ExH3o.get_resolution(cell) == 0
      end)
    end

    test "base cell numbers cover 0..121" do
      cells = ExH3o.get_res0_indexes()

      base_cells =
        Enum.map(cells, fn cell ->
          ExH3o.get_base_cell(cell)
        end)

      assert Enum.sort(base_cells) == Enum.to_list(0..121)
    end

    test "all cells are unique" do
      cells = ExH3o.get_res0_indexes()
      assert length(Enum.uniq(cells)) == 122
    end
  end

  describe "k_ring/2" do
    test "k=0 returns only the cell itself" do
      assert [cell] = ExH3o.k_ring(@valid_cell, 0)
      assert cell == @valid_cell
    end

    test "k=1 returns 7 cells" do
      cells = ExH3o.k_ring(@valid_cell, 1)
      assert length(cells) == 7
    end

    test "k=2 returns 19 cells" do
      cells = ExH3o.k_ring(@valid_cell, 2)
      assert length(cells) == 19
    end

    test "all returned cells are valid H3 indices" do
      cells = ExH3o.k_ring(@valid_cell, 2)

      Enum.each(cells, fn cell ->
        assert ExH3o.is_valid(cell)
      end)
    end

    test "all returned cells have the same resolution as input" do
      cells = ExH3o.k_ring(@valid_cell, 1)

      Enum.each(cells, fn cell ->
        assert ExH3o.get_resolution(cell) == 9
      end)
    end

    test "result includes the origin cell" do
      cells = ExH3o.k_ring(@valid_cell, 1)
      assert @valid_cell in cells
    end

    test "returns error for invalid cell index" do
      assert_raise ArgumentError, fn -> ExH3o.k_ring(@zero, 1) end
    end

    test "returns error for garbage cell" do
      assert_raise ArgumentError, fn -> ExH3o.k_ring(@garbage, 1) end
    end

    test "returns error for max uint64 cell" do
      assert_raise ArgumentError, fn -> ExH3o.k_ring(@max_uint64, 1) end
    end

    property "cell count follows 3k² + 3k + 1 formula for valid cells" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          k = 1
          cells = ExH3o.k_ring(cell, k)
          expected = 3 * k * k + 3 * k + 1
          assert length(cells) == expected
        end
      end
    end

    property "returns a value or raises ArgumentError for any inputs" do
      check all(
              cell <- non_negative_integer(),
              k <- integer(0..3)
            ) do
        if ExH3o.is_valid(cell) do
          cells = ExH3o.k_ring(cell, k)
          assert is_list(cells)
          Enum.each(cells, fn c -> assert is_integer(c) and c > 0 end)
        else
          assert_raise ArgumentError, fn -> ExH3o.k_ring(cell, k) end
        end
      end
    end
  end

  describe "indices_are_neighbors/2" do
    # Adjacent cell obtained from k_ring(@valid_cell, 1)
    @neighbor 0x8928308280BFFFF
    # Non-adjacent cell obtained from k_ring(@valid_cell, 2) minus k_ring(1)
    @non_adjacent 0x8928308281BFFFF
    # Child at resolution 10 (different resolution from @valid_cell res 9)
    @child_res10 0x8A28308280C7FFF

    test "adjacent cells at same resolution return true" do
      assert ExH3o.indices_are_neighbors(@valid_cell, @neighbor) == true
    end

    test "non-adjacent cells return false" do
      assert ExH3o.indices_are_neighbors(@valid_cell, @non_adjacent) == false
    end

    test "cells at different resolutions raise" do
      assert_raise ArgumentError, fn ->
        ExH3o.indices_are_neighbors(@valid_cell, @child_res10)
      end
    end

    test "invalid cell raises" do
      assert_raise ArgumentError, fn -> ExH3o.indices_are_neighbors(@zero, @valid_cell) end
    end

    test "invalid second cell raises" do
      assert_raise ArgumentError, fn -> ExH3o.indices_are_neighbors(@valid_cell, @zero) end
    end

    test "a cell is not a neighbor to itself" do
      assert ExH3o.indices_are_neighbors(@valid_cell, @valid_cell) == false
    end

    property "returns boolean or raises ArgumentError for any inputs" do
      check all(
              a <- non_negative_integer(),
              b <- non_negative_integer()
            ) do
        if ExH3o.is_valid(a) and ExH3o.is_valid(b) and
             ExH3o.get_resolution(a) == ExH3o.get_resolution(b) do
          assert is_boolean(ExH3o.indices_are_neighbors(a, b))
        else
          assert_raise ArgumentError, fn -> ExH3o.indices_are_neighbors(a, b) end
        end
      end
    end
  end

  describe "grid_distance/2" do
    @neighbor 0x8928308280BFFFF

    test "distance from a cell to itself is 0" do
      assert ExH3o.grid_distance(@valid_cell, @valid_cell) == 0
    end

    test "distance between adjacent cells is 1" do
      assert ExH3o.grid_distance(@valid_cell, @neighbor) == 1
    end

    test "invalid cell raises" do
      assert_raise ArgumentError, fn -> ExH3o.grid_distance(@zero, @valid_cell) end
    end

    test "invalid second cell raises" do
      assert_raise ArgumentError, fn -> ExH3o.grid_distance(@valid_cell, @zero) end
    end

    test "return type is integer (signed)" do
      dist = ExH3o.grid_distance(@valid_cell, @valid_cell)
      assert is_integer(dist)
    end

    property "returns integer or raises ArgumentError for any inputs" do
      check all(
              a <- non_negative_integer(),
              b <- non_negative_integer()
            ) do
        if ExH3o.is_valid(a) and ExH3o.is_valid(b) do
          try do
            dist = ExH3o.grid_distance(a, b)
            assert is_integer(dist)
          rescue
            ArgumentError -> :ok
          end
        else
          assert_raise ArgumentError, fn -> ExH3o.grid_distance(a, b) end
        end
      end
    end
  end

  describe "get_unidirectional_edge/2" do
    @neighbor 0x8928308280BFFFF
    @non_adjacent 0x8928308281BFFFF

    test "edge between adjacent cells returns a positive edge index" do
      edge = ExH3o.get_unidirectional_edge(@valid_cell, @neighbor)
      assert edge > 0
    end

    test "edge between non-adjacent cells raises" do
      assert_raise ArgumentError, fn ->
        ExH3o.get_unidirectional_edge(@valid_cell, @non_adjacent)
      end
    end

    test "invalid cell raises" do
      assert_raise ArgumentError, fn -> ExH3o.get_unidirectional_edge(@zero, @valid_cell) end
    end

    test "invalid second cell raises" do
      assert_raise ArgumentError, fn -> ExH3o.get_unidirectional_edge(@valid_cell, @zero) end
    end

    test "edge index is a valid non-negative integer" do
      edge = ExH3o.get_unidirectional_edge(@valid_cell, @neighbor)
      assert is_integer(edge)
      assert edge > 0
    end

    property "returns non-negative integer or raises ArgumentError for any inputs" do
      check all(
              a <- non_negative_integer(),
              b <- non_negative_integer()
            ) do
        try do
          edge = ExH3o.get_unidirectional_edge(a, b)
          assert is_integer(edge) and edge > 0
        rescue
          ArgumentError -> :ok
        end
      end
    end
  end

  describe "from_geo/2" do
    test "returns a cell for San Francisco coordinates at resolution 9" do
      cell = ExH3o.from_geo({37.7749, -122.4194}, 9)
      assert is_integer(cell)
      assert cell > 0
      assert ExH3o.is_valid(cell)
    end

    test "returned cell has the requested resolution" do
      cell = ExH3o.from_geo({37.7749, -122.4194}, 9)
      assert ExH3o.get_resolution(cell) == 9
    end

    test "works at all valid resolutions (0-15)" do
      Enum.each(0..15, fn res ->
        cell = ExH3o.from_geo({37.7749, -122.4194}, res)
        assert ExH3o.get_resolution(cell) == res
      end)
    end

    test "raises for latitude out of range" do
      assert_raise ArgumentError, fn -> ExH3o.from_geo({91.0, 0.0}, 9) end
    end

    test "raises for negative latitude out of range" do
      assert_raise ArgumentError, fn -> ExH3o.from_geo({-91.0, 0.0}, 9) end
    end

    test "raises for longitude out of range" do
      assert_raise ArgumentError, fn -> ExH3o.from_geo({0.0, 181.0}, 9) end
    end

    test "raises for resolution > 15" do
      assert_raise FunctionClauseError, fn -> ExH3o.from_geo({0.0, 0.0}, 16) end
    end

    test "raises for NaN atom in lat" do
      assert_raise FunctionClauseError, fn -> ExH3o.from_geo({:nan, 0.0}, 9) end
    end

    test "raises for NaN atom in lng" do
      assert_raise FunctionClauseError, fn -> ExH3o.from_geo({0.0, :nan}, 9) end
    end

    test "handles boundary coordinates: north pole" do
      cell = ExH3o.from_geo({90.0, 0.0}, 0)
      assert ExH3o.is_valid(cell)
    end

    test "handles boundary coordinates: south pole" do
      cell = ExH3o.from_geo({-90.0, 0.0}, 0)
      assert ExH3o.is_valid(cell)
    end

    test "handles boundary coordinates: antimeridian" do
      cell = ExH3o.from_geo({0.0, 180.0}, 0)
      assert ExH3o.is_valid(cell)
    end

    property "returns a cell or raises ArgumentError for valid coordinate ranges" do
      check all(
              lat <- float(min: -90.0, max: 90.0),
              lng <- float(min: -180.0, max: 180.0),
              res <- integer(0..15)
            ) do
        cell = ExH3o.from_geo({lat, lng}, res)
        assert ExH3o.is_valid(cell)
      end
    end
  end

  describe "to_geo/1" do
    test "returns a {lat, lng} tuple for a known valid cell" do
      assert {lat, lng} = ExH3o.to_geo(@valid_cell)
      assert is_float(lat)
      assert is_float(lng)
    end

    test "lat is in [-90, 90] and lng in [-180, 180]" do
      assert {lat, lng} = ExH3o.to_geo(@valid_cell)
      assert lat >= -90.0 and lat <= 90.0
      assert lng >= -180.0 and lng <= 180.0
    end

    test "raises for zero" do
      assert_raise ArgumentError, fn -> ExH3o.to_geo(@zero) end
    end

    test "raises for garbage" do
      assert_raise ArgumentError, fn -> ExH3o.to_geo(@garbage) end
    end

    test "raises for max uint64" do
      assert_raise ArgumentError, fn -> ExH3o.to_geo(@max_uint64) end
    end

    property "returns valid coordinates or error for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          {lat, lng} = ExH3o.to_geo(cell)
          assert lat >= -90.0 and lat <= 90.0
          assert lng >= -180.0 and lng <= 180.0
        else
          assert_raise ArgumentError, fn -> ExH3o.to_geo(cell) end
        end
      end
    end
  end

  describe "to_geo_boundary/1" do
    test "returns a vertices list for a known hexagon cell" do
      vertices = ExH3o.to_geo_boundary(@valid_cell)
      assert is_list(vertices)
      assert length(vertices) == 6
    end

    test "returns 5 vertices for a pentagon cell" do
      vertices = ExH3o.to_geo_boundary(@pentagon_cell)
      assert length(vertices) == 5
    end

    test "each vertex is a {lat, lng} tuple with valid ranges" do
      vertices = ExH3o.to_geo_boundary(@valid_cell)

      Enum.each(vertices, fn {lat, lng} ->
        assert is_float(lat)
        assert is_float(lng)
        assert lat >= -90.0 and lat <= 90.0
        assert lng >= -180.0 and lng <= 180.0
      end)
    end

    test "raises for zero" do
      assert_raise ArgumentError, fn -> ExH3o.to_geo_boundary(@zero) end
    end

    test "raises for garbage" do
      assert_raise ArgumentError, fn -> ExH3o.to_geo_boundary(@garbage) end
    end

    test "raises for max uint64" do
      assert_raise ArgumentError, fn -> ExH3o.to_geo_boundary(@max_uint64) end
    end

    property "returns 5 or 6 vertices with valid coordinates for any valid cell" do
      check all(cell <- non_negative_integer()) do
        if ExH3o.is_valid(cell) do
          vertices = ExH3o.to_geo_boundary(cell)
          assert length(vertices) in [5, 6]

          Enum.each(vertices, fn {lat, lng} ->
            assert lat >= -90.0 and lat <= 90.0
            assert lng >= -180.0 and lng <= 180.0
          end)
        else
          assert_raise ArgumentError, fn -> ExH3o.to_geo_boundary(cell) end
        end
      end
    end
  end

  describe "from_geo/to_geo roundtrip" do
    test "roundtrip produces coordinates within 0.01° of original" do
      coords = {37.7749, -122.4194}
      cell = ExH3o.from_geo(coords, 9)
      {lat, lng} = ExH3o.to_geo(cell)

      {orig_lat, orig_lng} = coords
      assert abs(lat - orig_lat) < 0.01
      assert abs(lng - orig_lng) < 0.01
    end

    property "re-encoding a decoded coordinate returns the same cell (FGE-507)" do
      # This is a *wrapper integration* test, not an h3o precision test.
      # We verify that our NIF boundary preserves cell-index data correctly:
      # from_geo encodes a coordinate as a cell, to_geo returns that cell's
      # centroid, and from_geo applied to the centroid must return the same
      # cell. If either NIF mangled its data (endianness, bit truncation,
      # byte-order mismatch), this property fails, but it makes no claim
      # about h3o's numerical precision at any latitude. That is the h3o
      # crate's concern, not ours. See FGE-507 for the principle.
      check all(
              lat <- float(min: -85.0, max: 85.0),
              lng <- float(min: -170.0, max: 170.0)
            ) do
        cell = ExH3o.from_geo({lat, lng}, 9)
        {rlat, rlng} = ExH3o.to_geo(cell)
        assert ExH3o.from_geo({rlat, rlng}, 9) == cell
      end
    end
  end

  describe "compact/1" do
    test "compact then uncompact roundtrips to original set" do
      children = ExH3o.children(@valid_cell, 10)
      compacted = ExH3o.compact(children)

      # Uncompact back to res 10 to verify roundtrip
      uncompacted = ExH3o.uncompact(compacted, 10)
      assert Enum.sort(uncompacted) == Enum.sort(children)
    end

    test "compact of already-compact set is idempotent" do
      children = ExH3o.children(@valid_cell, 10)
      compacted = ExH3o.compact(children)
      recompacted = ExH3o.compact(compacted)
      assert Enum.sort(recompacted) == Enum.sort(compacted)
    end

    test "mixed resolutions raise" do
      children_10 = ExH3o.children(@valid_cell, 10)
      children_11 = ExH3o.children(@valid_cell, 11)
      mixed = Enum.take(children_10, 1) ++ Enum.take(children_11, 1)
      assert_raise ArgumentError, fn -> ExH3o.compact(mixed) end
    end

    test "duplicates raise" do
      children = ExH3o.children(@valid_cell, 10)
      duplicated = children ++ Enum.take(children, 1)
      assert_raise ArgumentError, fn -> ExH3o.compact(duplicated) end
    end

    test "compact of a single cell returns that cell" do
      assert ExH3o.compact([@valid_cell]) == [@valid_cell]
    end

    test "compact of empty list returns empty list" do
      assert ExH3o.compact([]) == []
    end

    test "all compacted cells are valid H3 indices" do
      children = ExH3o.children(@valid_cell, 10)
      compacted = ExH3o.compact(children)

      Enum.each(compacted, fn cell ->
        assert ExH3o.is_valid(cell)
      end)
    end

    test "compacted set is smaller or equal in size" do
      children = ExH3o.children(@valid_cell, 10)
      compacted = ExH3o.compact(children)
      assert length(compacted) <= length(children)
    end
  end

  describe "uncompact/2" do
    test "uncompact expands to correct resolution" do
      uncompacted = ExH3o.uncompact([@valid_cell], 10)

      Enum.each(uncompacted, fn cell ->
        assert ExH3o.get_resolution(cell) == 10
      end)
    end

    test "uncompact at same resolution returns identity" do
      assert ExH3o.uncompact([@valid_cell], 9) == [@valid_cell]
    end

    test "uncompact of empty list returns empty list" do
      assert ExH3o.uncompact([], 5) == []
    end

    test "raises for coarser resolution" do
      assert_raise ArgumentError, fn -> ExH3o.uncompact([@valid_cell], 8) end
    end

    test "raises for resolution > 15" do
      assert_raise FunctionClauseError, fn -> ExH3o.uncompact([@valid_cell], 16) end
    end

    test "all uncompacted cells are valid H3 indices" do
      uncompacted = ExH3o.uncompact([@valid_cell], 10)

      Enum.each(uncompacted, fn cell ->
        assert ExH3o.is_valid(cell)
      end)
    end

    test "uncompact produces expected child count for hexagon" do
      uncompacted = ExH3o.uncompact([@valid_cell], 10)
      assert length(uncompacted) == 7
    end
  end

  describe "k_ring_distances/2" do
    test "k=0 returns only {cell, 0}" do
      assert [{cell, 0}] = ExH3o.k_ring_distances(@valid_cell, 0)
      assert cell == @valid_cell
    end

    test "k=1 has center at distance 0 and 6 neighbors at distance 1" do
      pairs = ExH3o.k_ring_distances(@valid_cell, 1)
      assert length(pairs) == 7

      {at_0, at_1} = Enum.split_with(pairs, fn {_cell, dist} -> dist == 0 end)
      assert length(at_0) == 1
      assert [{@valid_cell, 0}] = at_0
      assert length(at_1) == 6
      Enum.each(at_1, fn {_cell, dist} -> assert dist == 1 end)
    end

    test "k=2 returns 19 pairs with correct distance distribution" do
      pairs = ExH3o.k_ring_distances(@valid_cell, 2)
      assert length(pairs) == 19

      by_distance = Enum.group_by(pairs, fn {_cell, dist} -> dist end)
      assert length(by_distance[0]) == 1
      assert length(by_distance[1]) == 6
      assert length(by_distance[2]) == 12
    end

    test "returns same cells as k_ring" do
      ring_cells = ExH3o.k_ring(@valid_cell, 2)
      dist_pairs = ExH3o.k_ring_distances(@valid_cell, 2)
      dist_cells = Enum.map(dist_pairs, fn {cell, _dist} -> cell end)

      assert Enum.sort(ring_cells) == Enum.sort(dist_cells)
    end

    test "all returned cells are valid H3 indices" do
      pairs = ExH3o.k_ring_distances(@valid_cell, 2)

      Enum.each(pairs, fn {cell, _dist} ->
        assert ExH3o.is_valid(cell)
      end)
    end

    test "all distances are non-negative integers" do
      pairs = ExH3o.k_ring_distances(@valid_cell, 2)

      Enum.each(pairs, fn {_cell, dist} ->
        assert is_integer(dist) and dist >= 0
      end)
    end

    test "returns error for invalid cell index" do
      assert_raise ArgumentError, fn -> ExH3o.k_ring_distances(@zero, 1) end
    end

    test "returns error for garbage cell" do
      assert_raise ArgumentError, fn -> ExH3o.k_ring_distances(@garbage, 1) end
    end

    test "returns error for max uint64 cell" do
      assert_raise ArgumentError, fn -> ExH3o.k_ring_distances(@max_uint64, 1) end
    end

    property "returns a value or raises ArgumentError for any inputs" do
      check all(
              cell <- non_negative_integer(),
              k <- integer(0..3)
            ) do
        if ExH3o.is_valid(cell) do
          pairs = ExH3o.k_ring_distances(cell, k)
          assert is_list(pairs)

          Enum.each(pairs, fn {c, d} ->
            assert is_integer(c) and c > 0
            assert is_integer(d) and d >= 0
          end)
        else
          assert_raise ArgumentError, fn -> ExH3o.k_ring_distances(cell, k) end
        end
      end
    end
  end

  describe "polyfill/2" do
    # A small polygon around San Francisco (roughly 4 blocks)
    @sf_polygon [
      {37.7749, -122.4194},
      {37.7749, -122.4094},
      {37.7849, -122.4094},
      {37.7849, -122.4194},
      {37.7749, -122.4194}
    ]

    test "returns cells for a known polygon at resolution 9" do
      assert [_ | _] = cells = ExH3o.polyfill(@sf_polygon, 9)

      Enum.each(cells, fn cell ->
        assert ExH3o.is_valid(cell)
        assert ExH3o.get_resolution(cell) == 9
      end)
    end

    test "returns more cells at higher resolution" do
      cells_7 = ExH3o.polyfill(@sf_polygon, 7)
      cells_9 = ExH3o.polyfill(@sf_polygon, 9)
      assert length(cells_9) > length(cells_7)
    end

    test "returns empty list for degenerate polygon (single point)" do
      point = [{0.0, 0.0}, {0.0, 0.0}, {0.0, 0.0}, {0.0, 0.0}]
      assert ExH3o.polyfill(point, 0) == []
    end

    test "raises for resolution > 15" do
      assert_raise FunctionClauseError, fn -> ExH3o.polyfill(@sf_polygon, 16) end
    end

    test "raises for negative resolution" do
      assert_raise FunctionClauseError, fn -> ExH3o.polyfill(@sf_polygon, -1) end
    end

    test "raises for fewer than 3 distinct vertices" do
      line = [{0.0, 0.0}, {1.0, 1.0}]
      assert_raise ArgumentError, fn -> ExH3o.polyfill(line, 5) end
    end

    test "raises for empty list" do
      assert_raise ArgumentError, fn -> ExH3o.polyfill([], 5) end
    end

    test "all returned cells are unique" do
      cells = ExH3o.polyfill(@sf_polygon, 9)
      assert length(Enum.uniq(cells)) == length(cells)
    end

    test "works at resolution 0" do
      # Large polygon to ensure we get at least one cell at res 0
      large_polygon = [
        {-10.0, -10.0},
        {-10.0, 10.0},
        {10.0, 10.0},
        {10.0, -10.0},
        {-10.0, -10.0}
      ]

      assert [_ | _] = cells = ExH3o.polyfill(large_polygon, 0)

      Enum.each(cells, fn cell ->
        assert ExH3o.get_resolution(cell) == 0
      end)
    end

    test "works at resolution 15 with tiny polygon" do
      # Very small polygon, should still produce cells at res 15
      tiny = [
        {37.7749, -122.4194},
        {37.7749, -122.4193},
        {37.7750, -122.4193},
        {37.7750, -122.4194},
        {37.7749, -122.4194}
      ]

      assert [_ | _] = cells = ExH3o.polyfill(tiny, 15)

      Enum.each(cells, fn cell ->
        assert ExH3o.get_resolution(cell) == 15
      end)
    end

    test "returned cells are within or near the polygon" do
      cells = ExH3o.polyfill(@sf_polygon, 9)

      Enum.each(cells, fn cell ->
        assert {lat, lng} = ExH3o.to_geo(cell)
        # Cell centroids should be near the polygon (within ~0.02° tolerance)
        assert lat > 37.77 and lat < 37.79
        assert lng > -122.42 and lng < -122.40
      end)
    end

    test "polygon with closing vertex same as first produces same result as without" do
      open = [
        {37.7749, -122.4194},
        {37.7749, -122.4094},
        {37.7849, -122.4094},
        {37.7849, -122.4194}
      ]

      closed = open ++ [List.first(open)]

      cells_open = ExH3o.polyfill(open, 9)
      cells_closed = ExH3o.polyfill(closed, 9)
      assert Enum.sort(cells_open) == Enum.sort(cells_closed)
    end

    # Non-integer resolution with a valid polygon is a resolution-argument
    # type error, not a geometry error. The @spec allows both atoms; this
    # test pins the correct one.
    test "raises for non-integer resolution" do
      assert_raise FunctionClauseError, fn -> ExH3o.polyfill(@sf_polygon, "5") end
      assert_raise FunctionClauseError, fn -> ExH3o.polyfill(@sf_polygon, 5.0) end
      assert_raise FunctionClauseError, fn -> ExH3o.polyfill(@sf_polygon, nil) end
    end

    # Non-list vertices is a geometry-argument type error regardless of
    # what `resolution` looks like; even if resolution is a valid integer,
    # we should surface `:invalid_geometry` rather than `:invalid_resolution`.
    test "raises for non-list vertices" do
      assert_raise FunctionClauseError, fn -> ExH3o.polyfill("not a list", 9) end
      assert_raise FunctionClauseError, fn -> ExH3o.polyfill(nil, 9) end
      assert_raise FunctionClauseError, fn -> ExH3o.polyfill(%{}, 9) end
    end
  end
end
