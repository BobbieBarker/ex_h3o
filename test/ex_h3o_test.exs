defmodule ExH3oTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Known valid H3 cell at resolution 9
  @valid_cell 0x8928308280FFFFF
  # Pentagon cell: base cell 4 at resolution 0
  @pentagon_cell 0x8009FFFFFFFFFFF
  # Adjacent cell to @valid_cell (same resolution 9)
  @adjacent_cell 0x8928308280BFFFF
  # Non-adjacent cell to @valid_cell (same resolution 9, distance > 1)
  @non_adjacent_cell 0x8928308281BFFFF
  # Known directed edge from @valid_cell to @adjacent_cell
  @valid_edge 0x16928308280FFFFF
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

  describe "indices_are_neighbors/2" do
    test "adjacent cells at same resolution return {:ok, true}" do
      assert {:ok, true} = ExH3o.indices_are_neighbors(@valid_cell, @adjacent_cell)
    end

    test "non-adjacent cells return {:ok, false}" do
      assert {:ok, false} = ExH3o.indices_are_neighbors(@valid_cell, @non_adjacent_cell)
    end

    test "cells at different resolutions return {:error, :resolution_mismatch}" do
      assert {:error, :resolution_mismatch} =
               ExH3o.indices_are_neighbors(@valid_cell, @pentagon_cell)
    end

    test "invalid cell returns {:error, :invalid_index}" do
      assert {:error, :invalid_index} = ExH3o.indices_are_neighbors(@zero, @valid_cell)
      assert {:error, :invalid_index} = ExH3o.indices_are_neighbors(@valid_cell, @zero)
    end

    property "returns {:ok, boolean()} or an error for any two non-negative integers" do
      check all(a <- non_negative_integer(), b <- non_negative_integer()) do
        case ExH3o.indices_are_neighbors(a, b) do
          {:ok, result} -> assert is_boolean(result)
          {:error, :invalid_index} -> :ok
          {:error, :resolution_mismatch} -> :ok
        end
      end
    end
  end

  describe "grid_distance/2" do
    test "distance from cell to itself is 0" do
      assert {:ok, 0} = ExH3o.grid_distance(@valid_cell, @valid_cell)
    end

    test "distance between adjacent cells is 1" do
      assert {:ok, 1} = ExH3o.grid_distance(@valid_cell, @adjacent_cell)
    end

    test "invalid cell returns {:error, :invalid_index}" do
      assert {:error, :invalid_index} = ExH3o.grid_distance(@zero, @valid_cell)
      assert {:error, :invalid_index} = ExH3o.grid_distance(@valid_cell, @zero)
    end

    property "returns {:ok, integer()} or an error for any two non-negative integers" do
      check all(a <- non_negative_integer(), b <- non_negative_integer()) do
        case ExH3o.grid_distance(a, b) do
          {:ok, dist} -> assert is_integer(dist)
          {:error, :invalid_index} -> :ok
          {:error, :local_ij_error} -> :ok
        end
      end
    end
  end

  describe "get_unidirectional_edge/2" do
    test "edge between adjacent cells returns {:ok, edge_index} where edge_index > 0" do
      assert {:ok, edge} = ExH3o.get_unidirectional_edge(@valid_cell, @adjacent_cell)
      assert edge > 0
      assert edge == @valid_edge
    end

    test "edge between non-adjacent cells returns {:error, :not_neighbors}" do
      assert {:error, :not_neighbors} =
               ExH3o.get_unidirectional_edge(@valid_cell, @non_adjacent_cell)
    end

    test "invalid cell returns {:error, :invalid_index}" do
      assert {:error, :invalid_index} = ExH3o.get_unidirectional_edge(@zero, @valid_cell)
      assert {:error, :invalid_index} = ExH3o.get_unidirectional_edge(@valid_cell, @zero)
    end

    property "returns {:ok, non_neg_integer()} or an error for any two non-negative integers" do
      check all(a <- non_negative_integer(), b <- non_negative_integer()) do
        case ExH3o.get_unidirectional_edge(a, b) do
          {:ok, edge} -> assert is_integer(edge) and edge > 0
          {:error, :invalid_index} -> :ok
          {:error, :not_neighbors} -> :ok
        end
      end
    end
  end
end
