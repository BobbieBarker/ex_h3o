defmodule ExH3o.PrecompiledTest do
  use ExUnit.Case, async: true

  @checksum_file "checksum-Elixir.ExH3o.Native.exs"

  describe "hex package configuration" do
    test "checksum file exists in project root" do
      assert File.exists?(@checksum_file)
    end

    test "checksum file is valid Elixir term" do
      {checksums, _bindings} = Code.eval_file(@checksum_file)
      assert is_map(checksums)
    end

    test "package includes checksum file in hex files list" do
      package = ExH3o.MixProject.project()[:package]
      files = Keyword.get(package, :files)
      assert is_list(files)
      assert @checksum_file in files
    end

    test "package includes native source for force builds" do
      package = ExH3o.MixProject.project()[:package]
      files = Keyword.get(package, :files)
      assert "native/ex_h3o_nif/Cargo.toml" in files
      assert "native/ex_h3o_nif/Cargo.lock" in files
      assert "native/ex_h3o_nif/Makefile" in files
      assert "native/ex_h3o_nif/src" in files
      assert "native/ex_h3o_nif/c_src" in files
    end

    test "package description communicates design goals" do
      desc = ExH3o.MixProject.project()[:description]
      assert desc =~ "H3"
    end
  end
end
