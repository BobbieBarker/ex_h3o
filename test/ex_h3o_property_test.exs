defmodule ExH3oPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExH3o.Generators

  describe "from_geo produces valid cells" do
    property "any valid cell from from_geo passes is_valid" do
      check all(cell <- valid_cell()) do
        assert ExH3o.is_valid(cell)
      end
    end
  end

  describe "parent/2" do
    property "parent(cell, res) where res < cell res always succeeds" do
      check all(
              child_res <- integer(1..15),
              cell <- valid_cell(child_res),
              parent_res <- integer(0..(child_res - 1))
            ) do
        assert {:ok, parent} = ExH3o.parent(cell, parent_res)
        assert ExH3o.is_valid(parent)
        assert {:ok, ^parent_res} = ExH3o.get_resolution(parent)
      end
    end
  end

  describe "compact/uncompact roundtrip" do
    property "compact(uncompact(cells, res)) ≈ original (set equality)" do
      check all(
              res <- integer(0..5),
              cells <- valid_cell_set(res, 3)
            ) do
        cells = Enum.uniq(cells)
        target_res = res + 1

        {:ok, uncompacted} = ExH3o.uncompact(cells, target_res)
        {:ok, recompacted} = ExH3o.compact(uncompacted)

        assert Enum.sort(recompacted) == Enum.sort(cells)
      end
    end
  end

  describe "k_ring/2" do
    property "k_ring(cell, k) always contains the origin cell" do
      check all(
              cell <- valid_cell(5),
              k <- integer(0..3)
            ) do
        assert {:ok, ring} = ExH3o.k_ring(cell, k)
        assert cell in ring
      end
    end
  end

  describe "get_resolution/1 after from_geo/2" do
    property "get_resolution(from_geo(coord, res)) returns res" do
      check all(
              coord <- valid_coordinate(),
              res <- valid_resolution()
            ) do
        {:ok, cell} = ExH3o.from_geo(coord, res)
        assert {:ok, ^res} = ExH3o.get_resolution(cell)
      end
    end
  end

  describe "to_string/from_string roundtrip" do
    property "to_string -> from_string roundtrips" do
      check all(cell <- valid_cell()) do
        {:ok, str} = ExH3o.to_string(cell)
        assert {:ok, ^cell} = ExH3o.from_string(str)
      end
    end
  end
end
