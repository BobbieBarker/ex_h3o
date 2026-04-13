defmodule ExH3oTest do
  use ExUnit.Case, async: true

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
  end
end
