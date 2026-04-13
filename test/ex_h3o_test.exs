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
