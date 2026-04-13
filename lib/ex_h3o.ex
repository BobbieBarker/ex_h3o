defmodule ExH3o do
  @moduledoc """
  Elixir bindings for [h3o](https://github.com/HydroniumLabs/h3o), a Rust
  implementation of the H3 geospatial indexing system.

  H3 is a hierarchical hexagonal grid system that maps geographic coordinates
  to hexagonal cells at multiple resolutions (0-15). It is used for spatial
  indexing, analysis, and aggregation of geospatial data.
  """

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
end
