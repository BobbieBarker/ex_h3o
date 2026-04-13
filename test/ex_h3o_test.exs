defmodule ExH3oTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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
      assert {:ok, 9} = ExH3o.get_resolution(@valid_cell)
    end

    test "returns resolution 0 for pentagon base cell" do
      assert {:ok, 0} = ExH3o.get_resolution(@pentagon_cell)
    end

    test "returns error for zero" do
      assert {:error, :invalid_index} = ExH3o.get_resolution(@zero)
    end

    test "returns error for max uint64" do
      assert {:error, :invalid_index} = ExH3o.get_resolution(@max_uint64)
    end

    test "returns error for garbage" do
      assert {:error, :invalid_index} = ExH3o.get_resolution(@garbage)
    end

    property "returns {:ok, 0..15} or {:error, :invalid_index} for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        case ExH3o.get_resolution(cell) do
          {:ok, res} -> assert res in 0..15
          {:error, :invalid_index} -> :ok
        end
      end
    end
  end

  describe "get_base_cell/1" do
    test "returns a valid base cell number for known cell" do
      assert {:ok, base} = ExH3o.get_base_cell(@valid_cell)
      assert base in 0..121
    end

    test "returns a valid base cell for pentagon cell" do
      assert {:ok, base} = ExH3o.get_base_cell(@pentagon_cell)
      assert base in 0..121
    end

    test "returns error for zero" do
      assert {:error, :invalid_index} = ExH3o.get_base_cell(@zero)
    end

    test "returns error for max uint64" do
      assert {:error, :invalid_index} = ExH3o.get_base_cell(@max_uint64)
    end

    test "returns error for garbage" do
      assert {:error, :invalid_index} = ExH3o.get_base_cell(@garbage)
    end

    property "returns {:ok, 0..121} or {:error, :invalid_index} for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        case ExH3o.get_base_cell(cell) do
          {:ok, base} -> assert base in 0..121
          {:error, :invalid_index} -> :ok
        end
      end
    end
  end

  describe "is_pentagon/1" do
    test "returns false for a known hexagon" do
      assert {:ok, false} = ExH3o.is_pentagon(@valid_cell)
    end

    test "returns true for a known pentagon" do
      assert {:ok, true} = ExH3o.is_pentagon(@pentagon_cell)
    end

    test "returns error for zero" do
      assert {:error, :invalid_index} = ExH3o.is_pentagon(@zero)
    end

    test "returns error for max uint64" do
      assert {:error, :invalid_index} = ExH3o.is_pentagon(@max_uint64)
    end

    test "returns error for garbage" do
      assert {:error, :invalid_index} = ExH3o.is_pentagon(@garbage)
    end

    property "returns {:ok, boolean()} or {:error, :invalid_index} for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        case ExH3o.is_pentagon(cell) do
          {:ok, result} -> assert is_boolean(result)
          {:error, :invalid_index} -> :ok
        end
      end
    end
  end

  describe "is_class3/1" do
    test "returns true for odd resolution (res 9)" do
      assert {:ok, true} = ExH3o.is_class3(@valid_cell)
    end

    test "returns false for even resolution (res 0)" do
      assert {:ok, false} = ExH3o.is_class3(@pentagon_cell)
    end

    test "returns error for zero" do
      assert {:error, :invalid_index} = ExH3o.is_class3(@zero)
    end

    test "returns error for max uint64" do
      assert {:error, :invalid_index} = ExH3o.is_class3(@max_uint64)
    end

    test "returns error for garbage" do
      assert {:error, :invalid_index} = ExH3o.is_class3(@garbage)
    end

    property "returns {:ok, boolean()} or {:error, :invalid_index} for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        case ExH3o.is_class3(cell) do
          {:ok, result} -> assert is_boolean(result)
          {:error, :invalid_index} -> :ok
        end
      end
    end
  end

  describe "children/2" do
    test "hexagon at next resolution returns 7 children" do
      assert {:ok, children} = ExH3o.children(@valid_cell, 10)
      assert length(children) == 7

      Enum.each(children, fn child ->
        assert {:ok, 10} = ExH3o.get_resolution(child)
      end)
    end

    test "pentagon at next resolution returns 6 children" do
      assert {:ok, children} = ExH3o.children(@pentagon_cell, 1)
      assert length(children) == 6

      Enum.each(children, fn child ->
        assert {:ok, 1} = ExH3o.get_resolution(child)
      end)
    end

    test "children count at res+2 is 49 for hexagon" do
      assert {:ok, children} = ExH3o.children(@valid_cell, 11)
      assert length(children) == 49

      Enum.each(children, fn child ->
        assert {:ok, 11} = ExH3o.get_resolution(child)
      end)
    end

    test "all children are valid H3 cells" do
      assert {:ok, children} = ExH3o.children(@valid_cell, 10)

      Enum.each(children, fn child ->
        assert ExH3o.is_valid(child)
      end)
    end

    test "children at same resolution returns only self" do
      assert {:ok, [cell]} = ExH3o.children(@valid_cell, 9)
      assert cell == @valid_cell
    end

    test "returns error for coarser resolution" do
      assert {:error, :invalid_resolution} = ExH3o.children(@valid_cell, 8)
    end

    test "returns error for resolution out of range" do
      assert {:error, :invalid_resolution} = ExH3o.children(@valid_cell, 16)
    end

    test "returns error for invalid cell index" do
      assert {:error, :invalid_index} = ExH3o.children(@zero, 5)
    end

    test "returns error for garbage cell" do
      assert {:error, :invalid_index} = ExH3o.children(@garbage, 5)
    end

    test "returns error for max uint64 cell" do
      assert {:error, :invalid_index} = ExH3o.children(@max_uint64, 5)
    end

    property "children at next resolution returns list of valid cells" do
      check all(cell <- non_negative_integer()) do
        with {:ok, res} when res < 15 <- ExH3o.get_resolution(cell),
             {:ok, children} <- ExH3o.children(cell, res + 1) do
          assert is_list(children)
          assert length(children) in [6, 7]

          Enum.each(children, fn child ->
            assert {:ok, ^res} =
                     ExH3o.get_resolution(child) |> then(fn {:ok, r} -> {:ok, r - 1} end)
          end)
        end
      end
    end

    property "returns {:ok, _} or {:error, :invalid_index | :invalid_resolution} for any inputs" do
      check all(
              cell <- non_negative_integer(),
              res <- integer(0..15)
            ) do
        case ExH3o.children(cell, res) do
          {:ok, children} ->
            assert is_list(children)
            Enum.each(children, fn child -> assert is_integer(child) and child > 0 end)

          {:error, :invalid_index} ->
            :ok

          {:error, :invalid_resolution} ->
            :ok
        end
      end
    end
  end

  describe "parent/2" do
    test "returns parent at coarser resolution" do
      assert {:ok, parent_cell} = ExH3o.parent(@valid_cell, 8)
      assert {:ok, 8} = ExH3o.get_resolution(parent_cell)
    end

    test "identity: parent at same resolution returns self" do
      assert {:ok, @valid_cell} = ExH3o.parent(@valid_cell, 9)
    end

    test "chain: transitive parent lookup" do
      assert {:ok, parent_8} = ExH3o.parent(@valid_cell, 8)
      assert {:ok, parent_7_via_8} = ExH3o.parent(parent_8, 7)
      assert {:ok, parent_7_direct} = ExH3o.parent(@valid_cell, 7)
      assert parent_7_via_8 == parent_7_direct
    end

    test "returns error for finer resolution than cell" do
      assert {:error, :invalid_resolution} = ExH3o.parent(@valid_cell, 10)
    end

    test "identity: res 0 cell at resolution 0 returns self" do
      assert {:ok, @pentagon_cell} = ExH3o.parent(@pentagon_cell, 0)
    end

    test "returns error for invalid cell index" do
      assert {:error, :invalid_index} = ExH3o.parent(@zero, 5)
    end

    test "returns error for resolution out of range" do
      assert {:error, :invalid_resolution} = ExH3o.parent(@valid_cell, 16)
    end

    test "returns error for garbage cell" do
      assert {:error, :invalid_index} = ExH3o.parent(@garbage, 5)
    end

    property "parent at coarser resolution has the target resolution" do
      check all(cell <- non_negative_integer()) do
        with {:ok, res} when res > 0 <- ExH3o.get_resolution(cell),
             {:ok, parent} <- ExH3o.parent(cell, res - 1) do
          assert {:ok, target} = ExH3o.get_resolution(parent)
          assert target == res - 1
        end
      end
    end

    property "returns {:ok, _} or {:error, :invalid_index | :invalid_resolution} for any inputs" do
      check all(
              cell <- non_negative_integer(),
              res <- integer(0..15)
            ) do
        case ExH3o.parent(cell, res) do
          {:ok, parent} -> assert is_integer(parent) and parent > 0
          {:error, :invalid_index} -> :ok
          {:error, :invalid_resolution} -> :ok
        end
      end
    end
  end

  describe "to_string/1" do
    test "converts valid cell to lowercase hex string" do
      assert {:ok, "8928308280fffff"} = ExH3o.to_string(@valid_cell)
    end

    test "converts pentagon cell to lowercase hex string" do
      assert {:ok, "8009fffffffffff"} = ExH3o.to_string(@pentagon_cell)
    end

    test "returns error for zero (invalid index)" do
      assert {:error, :invalid_index} = ExH3o.to_string(@zero)
    end

    test "returns error for max uint64" do
      assert {:error, :invalid_index} = ExH3o.to_string(@max_uint64)
    end

    test "returns error for garbage value" do
      assert {:error, :invalid_index} = ExH3o.to_string(@garbage)
    end

    property "returns {:ok, hex_string} or {:error, :invalid_index} for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        case ExH3o.to_string(cell) do
          {:ok, hex} ->
            assert is_binary(hex)
            assert Regex.match?(~r/\A[0-9a-f]+\z/, hex)

          {:error, :invalid_index} ->
            :ok
        end
      end
    end
  end

  describe "max_k_ring_size/1" do
    test "k=0 returns 1" do
      assert {:ok, 1} = ExH3o.max_k_ring_size(0)
    end

    test "k=1 returns 7" do
      assert {:ok, 7} = ExH3o.max_k_ring_size(1)
    end

    test "k=2 returns 19" do
      assert {:ok, 19} = ExH3o.max_k_ring_size(2)
    end

    test "k=3 returns 37" do
      assert {:ok, 37} = ExH3o.max_k_ring_size(3)
    end

    test "matches formula 3k² + 3k + 1 for k=0..100" do
      for k <- 0..100 do
        expected = 3 * k * k + 3 * k + 1
        assert {:ok, ^expected} = ExH3o.max_k_ring_size(k), "failed for k=#{k}"
      end
    end

    test "returns error for negative k" do
      assert {:error, :invalid_k} = ExH3o.max_k_ring_size(-1)
    end

    test "returns error for non-integer k" do
      assert {:error, :invalid_k} = ExH3o.max_k_ring_size(1.5)
      assert {:error, :invalid_k} = ExH3o.max_k_ring_size("2")
    end
  end

  describe "from_string/1" do
    test "parses valid hex string to cell index" do
      assert {:ok, @valid_cell} = ExH3o.from_string("8928308280fffff")
    end

    test "parses pentagon cell hex string" do
      assert {:ok, @pentagon_cell} = ExH3o.from_string("8009fffffffffff")
    end

    test "returns error for non-hex string" do
      assert {:error, :invalid_string} = ExH3o.from_string("not_hex")
    end

    test "returns error for empty string" do
      assert {:error, :invalid_string} = ExH3o.from_string("")
    end

    test "returns error for valid hex but invalid H3 index" do
      assert {:error, :invalid_string} = ExH3o.from_string("0000000000000000")
    end

    property "roundtrip: to_string then from_string returns original cell" do
      check all(cell <- non_negative_integer()) do
        with {:ok, hex} <- ExH3o.to_string(cell) do
          assert {:ok, ^cell} = ExH3o.from_string(hex)
        end
      end
    end

    property "roundtrip: from_string then to_string returns original hex (lowercase)" do
      check all(cell <- non_negative_integer()) do
        with {:ok, hex} <- ExH3o.to_string(cell) do
          assert {:ok, ^hex} =
                   ExH3o.from_string(hex) |> then(fn {:ok, c} -> ExH3o.to_string(c) end)
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
        assert {:ok, ^expected} = ExH3o.num_hexagons(res), "failed for res=#{res}"
      end
    end

    test "returns error for resolution -1" do
      assert {:error, :invalid_resolution} = ExH3o.num_hexagons(-1)
    end

    test "returns error for resolution 16" do
      assert {:error, :invalid_resolution} = ExH3o.num_hexagons(16)
    end
  end

  describe "edge_length_kilometers/1" do
    test "resolution 0 is approximately 1281 km" do
      assert {:ok, length} = ExH3o.edge_length_kilometers(0)
      assert_in_delta length, 1281.256011, 0.001
    end

    test "resolution 15 is sub-meter" do
      assert {:ok, length} = ExH3o.edge_length_kilometers(15)
      assert length < 0.001
    end

    test "returns error for invalid resolution" do
      assert {:error, :invalid_resolution} = ExH3o.edge_length_kilometers(-1)
      assert {:error, :invalid_resolution} = ExH3o.edge_length_kilometers(16)
    end

    test "lengths decrease monotonically with resolution" do
      lengths =
        for res <- 0..15 do
          {:ok, length} = ExH3o.edge_length_kilometers(res)
          length
        end

      for [a, b] <- Enum.chunk_every(lengths, 2, 1, :discard) do
        assert a > b
      end
    end
  end

  describe "edge_length_meters/1" do
    test "resolution 0 is approximately 1,281,256 m" do
      assert {:ok, length} = ExH3o.edge_length_meters(0)
      assert_in_delta length, 1_281_256.011, 0.01
    end

    test "values are 1000x the km values" do
      for res <- 0..15 do
        {:ok, km} = ExH3o.edge_length_kilometers(res)
        {:ok, m} = ExH3o.edge_length_meters(res)
        assert_in_delta m, km * 1000, 0.01, "failed for res=#{res}"
      end
    end

    test "returns error for invalid resolution" do
      assert {:error, :invalid_resolution} = ExH3o.edge_length_meters(-1)
      assert {:error, :invalid_resolution} = ExH3o.edge_length_meters(16)
    end
  end

  describe "hex_area_km2/1" do
    test "resolution 0 is approximately 4.36 million km²" do
      assert {:ok, area} = ExH3o.hex_area_km2(0)
      assert_in_delta area, 4_357_449.416, 0.001
    end

    test "resolution 15 is sub-square-meter" do
      assert {:ok, area} = ExH3o.hex_area_km2(15)
      assert area < 0.000001
    end

    test "returns error for invalid resolution" do
      assert {:error, :invalid_resolution} = ExH3o.hex_area_km2(-1)
      assert {:error, :invalid_resolution} = ExH3o.hex_area_km2(16)
    end

    test "areas decrease monotonically with resolution" do
      areas =
        for res <- 0..15 do
          {:ok, area} = ExH3o.hex_area_km2(res)
          area
        end

      for [a, b] <- Enum.chunk_every(areas, 2, 1, :discard) do
        assert a > b
      end
    end
  end

  describe "hex_area_m2/1" do
    test "resolution 0 is approximately 4.36 trillion m²" do
      assert {:ok, area} = ExH3o.hex_area_m2(0)
      assert_in_delta area, 4_357_449_416_078.39, 0.1
    end

    test "values are 1_000_000x the km² values" do
      for res <- 0..15 do
        {:ok, km2} = ExH3o.hex_area_km2(res)
        {:ok, m2} = ExH3o.hex_area_m2(res)
        assert_in_delta m2, km2 * 1_000_000, 0.1, "failed for res=#{res}"
      end
    end

    test "returns error for invalid resolution" do
      assert {:error, :invalid_resolution} = ExH3o.hex_area_m2(-1)
      assert {:error, :invalid_resolution} = ExH3o.hex_area_m2(16)
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
        assert {:ok, 0} = ExH3o.get_resolution(cell)
      end)
    end

    test "base cell numbers cover 0..121" do
      cells = ExH3o.get_res0_indexes()

      base_cells =
        Enum.map(cells, fn cell ->
          {:ok, bc} = ExH3o.get_base_cell(cell)
          bc
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
      assert {:ok, [cell]} = ExH3o.k_ring(@valid_cell, 0)
      assert cell == @valid_cell
    end

    test "k=1 returns 7 cells" do
      assert {:ok, cells} = ExH3o.k_ring(@valid_cell, 1)
      assert length(cells) == 7
    end

    test "k=2 returns 19 cells" do
      assert {:ok, cells} = ExH3o.k_ring(@valid_cell, 2)
      assert length(cells) == 19
    end

    test "all returned cells are valid H3 indices" do
      assert {:ok, cells} = ExH3o.k_ring(@valid_cell, 2)

      Enum.each(cells, fn cell ->
        assert ExH3o.is_valid(cell)
      end)
    end

    test "all returned cells have the same resolution as input" do
      assert {:ok, cells} = ExH3o.k_ring(@valid_cell, 1)

      Enum.each(cells, fn cell ->
        assert {:ok, 9} = ExH3o.get_resolution(cell)
      end)
    end

    test "result includes the origin cell" do
      assert {:ok, cells} = ExH3o.k_ring(@valid_cell, 1)
      assert @valid_cell in cells
    end

    test "returns error for invalid cell index" do
      assert {:error, :invalid_index} = ExH3o.k_ring(@zero, 1)
    end

    test "returns error for garbage cell" do
      assert {:error, :invalid_index} = ExH3o.k_ring(@garbage, 1)
    end

    test "returns error for max uint64 cell" do
      assert {:error, :invalid_index} = ExH3o.k_ring(@max_uint64, 1)
    end

    property "cell count follows 3k² + 3k + 1 formula for valid cells" do
      check all(cell <- non_negative_integer()) do
        with {:ok, _res} <- ExH3o.get_resolution(cell) do
          k = 1
          {:ok, cells} = ExH3o.k_ring(cell, k)
          expected = 3 * k * k + 3 * k + 1
          assert length(cells) == expected
        end
      end
    end

    property "returns {:ok, _} or {:error, :invalid_index} for any inputs" do
      check all(
              cell <- non_negative_integer(),
              k <- integer(0..3)
            ) do
        case ExH3o.k_ring(cell, k) do
          {:ok, cells} ->
            assert is_list(cells)
            Enum.each(cells, fn c -> assert is_integer(c) and c > 0 end)

          {:error, :invalid_index} ->
            :ok
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

    test "adjacent cells at same resolution return {:ok, true}" do
      assert {:ok, true} = ExH3o.indices_are_neighbors(@valid_cell, @neighbor)
    end

    test "non-adjacent cells return {:ok, false}" do
      assert {:ok, false} = ExH3o.indices_are_neighbors(@valid_cell, @non_adjacent)
    end

    test "cells at different resolutions return {:error, :resolution_mismatch}" do
      assert {:error, :resolution_mismatch} =
               ExH3o.indices_are_neighbors(@valid_cell, @child_res10)
    end

    test "invalid cell returns {:error, :invalid_index}" do
      assert {:error, :invalid_index} = ExH3o.indices_are_neighbors(@zero, @valid_cell)
    end

    test "invalid second cell returns {:error, :invalid_index}" do
      assert {:error, :invalid_index} = ExH3o.indices_are_neighbors(@valid_cell, @zero)
    end

    test "a cell is not a neighbor to itself" do
      assert {:ok, false} = ExH3o.indices_are_neighbors(@valid_cell, @valid_cell)
    end

    property "returns {:ok, boolean()} or {:error, atom()} for any inputs" do
      check all(
              a <- non_negative_integer(),
              b <- non_negative_integer()
            ) do
        case ExH3o.indices_are_neighbors(a, b) do
          {:ok, result} -> assert is_boolean(result)
          {:error, :invalid_index} -> :ok
          {:error, :resolution_mismatch} -> :ok
        end
      end
    end
  end

  describe "grid_distance/2" do
    @neighbor 0x8928308280BFFFF

    test "distance from a cell to itself is 0" do
      assert {:ok, 0} = ExH3o.grid_distance(@valid_cell, @valid_cell)
    end

    test "distance between adjacent cells is 1" do
      assert {:ok, 1} = ExH3o.grid_distance(@valid_cell, @neighbor)
    end

    test "invalid cell returns {:error, :invalid_index}" do
      assert {:error, :invalid_index} = ExH3o.grid_distance(@zero, @valid_cell)
    end

    test "invalid second cell returns {:error, :invalid_index}" do
      assert {:error, :invalid_index} = ExH3o.grid_distance(@valid_cell, @zero)
    end

    test "return type is integer (signed)" do
      assert {:ok, dist} = ExH3o.grid_distance(@valid_cell, @valid_cell)
      assert is_integer(dist)
    end

    property "returns {:ok, integer()} or {:error, atom()} for any inputs" do
      check all(
              a <- non_negative_integer(),
              b <- non_negative_integer()
            ) do
        case ExH3o.grid_distance(a, b) do
          {:ok, dist} -> assert is_integer(dist)
          {:error, :invalid_index} -> :ok
          {:error, :local_ij_error} -> :ok
        end
      end
    end
  end

  describe "get_unidirectional_edge/2" do
    @neighbor 0x8928308280BFFFF
    @non_adjacent 0x8928308281BFFFF

    test "edge between adjacent cells returns {:ok, edge_index} where edge_index > 0" do
      assert {:ok, edge} = ExH3o.get_unidirectional_edge(@valid_cell, @neighbor)
      assert edge > 0
    end

    test "edge between non-adjacent cells returns {:error, :not_neighbors}" do
      assert {:error, :not_neighbors} =
               ExH3o.get_unidirectional_edge(@valid_cell, @non_adjacent)
    end

    test "invalid cell returns {:error, :invalid_index}" do
      assert {:error, :invalid_index} = ExH3o.get_unidirectional_edge(@zero, @valid_cell)
    end

    test "invalid second cell returns {:error, :invalid_index}" do
      assert {:error, :invalid_index} = ExH3o.get_unidirectional_edge(@valid_cell, @zero)
    end

    test "edge index is a valid non-negative integer" do
      assert {:ok, edge} = ExH3o.get_unidirectional_edge(@valid_cell, @neighbor)
      assert is_integer(edge)
      assert edge > 0
    end

    property "returns {:ok, non_neg_integer()} or {:error, atom()} for any inputs" do
      check all(
              a <- non_negative_integer(),
              b <- non_negative_integer()
            ) do
        case ExH3o.get_unidirectional_edge(a, b) do
          {:ok, edge} -> assert is_integer(edge) and edge > 0
          {:error, :invalid_index} -> :ok
          {:error, :not_neighbors} -> :ok
        end
      end
    end
  end
end
