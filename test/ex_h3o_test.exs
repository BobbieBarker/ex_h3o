defmodule ExH3oTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  describe "is_valid/1" do
    test "returns true for a known valid H3 cell" do
      assert ExH3o.is_valid(0x8928308280FFFFF)
    end

    test "returns false for zero" do
      refute ExH3o.is_valid(0)
    end

    test "returns false for max uint64" do
      refute ExH3o.is_valid(0xFFFFFFFFFFFFFFFF)
    end

    test "returns false for random garbage value" do
      refute ExH3o.is_valid(0xDEADBEEF)
    end

    property "always returns a boolean for any non-negative integer" do
      check all(cell <- non_negative_integer()) do
        result = ExH3o.is_valid(cell)
        assert is_boolean(result)
      end
    end
  end

  describe "from_geo/2" do
    test "returns {:ok, cell} for valid coordinates at resolution 9" do
      assert {:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, 9)
      assert is_integer(cell)
      assert cell > 0
      assert ExH3o.is_valid(cell)
    end

    test "returns {:error, :invalid_coordinates} for lat out of range" do
      assert {:error, :invalid_coordinates} = ExH3o.from_geo({91.0, 0.0}, 9)
    end

    test "returns {:error, :invalid_coordinates} for lat below range" do
      assert {:error, :invalid_coordinates} = ExH3o.from_geo({-91.0, 0.0}, 9)
    end

    test "returns {:error, :invalid_resolution} for resolution > 15" do
      assert {:error, :invalid_resolution} = ExH3o.from_geo({0.0, 0.0}, 16)
    end

    test "returns {:error, :invalid_coordinates} for NaN latitude" do
      assert {:error, :invalid_coordinates} = ExH3o.from_geo({:nan, 0.0}, 9)
    end

    test "returns {:error, :invalid_coordinates} for NaN longitude" do
      assert {:error, :invalid_coordinates} = ExH3o.from_geo({0.0, :nan}, 9)
    end

    test "works at all valid resolutions" do
      for res <- 0..15 do
        assert {:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, res)
        assert ExH3o.is_valid(cell)
      end
    end

    property "always returns {:ok, cell} for valid lat/lng ranges" do
      check all(
              lat <- float(min: -90.0, max: 90.0),
              lng <- float(min: -180.0, max: 180.0),
              res <- integer(0..15)
            ) do
        assert {:ok, cell} = ExH3o.from_geo({lat, lng}, res)
        assert is_integer(cell)
        assert ExH3o.is_valid(cell)
      end
    end
  end

  describe "to_geo/1" do
    test "returns {:ok, {lat, lng}} for a valid cell" do
      {:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, 9)
      assert {:ok, {lat, lng}} = ExH3o.to_geo(cell)
      assert lat >= -90.0 and lat <= 90.0
      assert lng >= -180.0 and lng <= 180.0
    end

    test "returns {:error, :invalid_index} for zero" do
      assert {:error, :invalid_index} = ExH3o.to_geo(0)
    end

    test "returns {:error, :invalid_index} for invalid cell" do
      assert {:error, :invalid_index} = ExH3o.to_geo(0xDEADBEEF)
    end

    test "roundtrip from_geo -> to_geo produces coordinates within 0.01°" do
      original_lat = 37.7749
      original_lng = -122.4194

      {:ok, cell} = ExH3o.from_geo({original_lat, original_lng}, 9)
      {:ok, {lat, lng}} = ExH3o.to_geo(cell)

      assert abs(lat - original_lat) < 0.01
      assert abs(lng - original_lng) < 0.01
    end

    property "roundtrip produces coordinates close to original at res >= 9" do
      check all(
              lat <- float(min: -85.0, max: 85.0),
              lng <- float(min: -170.0, max: 170.0),
              res <- integer(9..15)
            ) do
        {:ok, cell} = ExH3o.from_geo({lat, lng}, res)
        {:ok, {result_lat, result_lng}} = ExH3o.to_geo(cell)

        # H3 cells at res 9 have ~174m edge length; 0.02° ≈ 2.2km is generous
        assert abs(result_lat - lat) < 0.02
        assert abs(result_lng - lng) < 0.02
      end
    end
  end

  describe "to_geo_boundary/1" do
    test "returns {:ok, vertices} with 6 vertices for a hexagonal cell" do
      {:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, 9)
      assert {:ok, vertices} = ExH3o.to_geo_boundary(cell)
      assert length(vertices) == 6
    end

    test "each vertex is a {lat, lng} tuple with valid ranges" do
      {:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, 9)
      {:ok, vertices} = ExH3o.to_geo_boundary(cell)

      for {lat, lng} <- vertices do
        assert is_float(lat)
        assert is_float(lng)
        assert lat >= -90.0 and lat <= 90.0
        assert lng >= -180.0 and lng <= 180.0
      end
    end

    test "returns {:error, :invalid_index} for zero" do
      assert {:error, :invalid_index} = ExH3o.to_geo_boundary(0)
    end

    test "returns {:error, :invalid_index} for invalid cell" do
      assert {:error, :invalid_index} = ExH3o.to_geo_boundary(0xDEADBEEF)
    end

    test "vertex count is 5 or 6 (pentagon or hexagon)" do
      {:ok, cell} = ExH3o.from_geo({37.7749, -122.4194}, 9)
      {:ok, vertices} = ExH3o.to_geo_boundary(cell)
      assert length(vertices) in 5..7
    end

    property "boundary vertices are always valid coordinates" do
      check all(
              lat <- float(min: -90.0, max: 90.0),
              lng <- float(min: -180.0, max: 180.0),
              res <- integer(0..15)
            ) do
        {:ok, cell} = ExH3o.from_geo({lat, lng}, res)
        {:ok, vertices} = ExH3o.to_geo_boundary(cell)

        assert length(vertices) in 5..7

        for {v_lat, v_lng} <- vertices do
          assert v_lat >= -90.0 and v_lat <= 90.0
          assert v_lng >= -180.0 and v_lng <= 180.0
        end
      end
    end
  end
end
