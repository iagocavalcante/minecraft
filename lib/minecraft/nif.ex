defmodule Minecraft.NIF do
  @moduledoc """
  NIFs for dealing with chunks.
  """
  @on_load :load_nifs

  @doc false
  @spec load_nifs() :: :ok | {:error, any}
  def load_nifs() do
    path = :filename.join(:code.priv_dir(:minecraft), ~c"nifs")
    :ok = :erlang.load_nif(path, 0)
  end

  @doc """
  Sets the random seed used for world generation.
  """
  @spec set_random_seed(integer) :: :ok
  def set_random_seed(_seed) do
    # Don't raise here, or Dialyzer complains
    :erlang.nif_error("NIF set_random_seed/1 not implemented")
  end

  @doc """
  Generates a chunk given x and y coordinates.

  Note that these must be chunk coordinates, as they get multiplied by 16
  in the NIF.
  """
  @spec generate_chunk(integer, integer) :: {:ok, any} | {:error, any}
  def generate_chunk(_chunk_x, _chunk_z) do
    # Don't raise here, or Dialyzer complains
    :erlang.nif_error("NIF generate_chunk/2 not implemented")
  end

  @doc """
  Serializes a Chunk.
  """
  @spec serialize_chunk(any) :: {:ok, any} | {:error, any}
  def serialize_chunk(_chunk) do
    # Don't raise here, or Dialyzer complains
    :erlang.nif_error("NIF serialize_chunk/1 not implemented")
  end

  @doc """
  Gets coordinates of a chunk.
  """
  @spec get_chunk_coordinates(any) :: {:ok, {integer, integer}} | :error
  def get_chunk_coordinates(_chunk) do
    # Don't raise here, or Dialyzer complains
    :erlang.nif_error("NIF get_chunk_coordinates/1 not implemented")
  end

  @doc """
  Gets the number of chunk sections in a chunk.
  """
  @spec num_chunk_sections(any) :: {:ok, integer} | :error
  def num_chunk_sections(_chunk) do
    # Don't raise here, or Dialyzer complains
    :erlang.nif_error("NIF num_chunk_sections/1 not implemented")
  end

  @doc """
  Gets the biome data for a chunk.
  """
  @spec chunk_biome_data(any) :: {:ok, binary} | :error
  def chunk_biome_data(_chunk) do
    # Don't raise here, or Dialyzer complains
    :erlang.nif_error("NIF chunk_biome_data/1 not implemented")
  end

  @doc """
  Gets the heightmap of a chunk as a 256-byte binary indexed by `z * 16 + x`.
  """
  @spec chunk_heightmap(any) :: {:ok, binary} | :error
  def chunk_heightmap(_chunk) do
    # Don't raise here, or Dialyzer complains
    :erlang.nif_error("NIF chunk_heightmap/1 not implemented")
  end

  @doc """
  Gets the raw block types of one chunk section: a binary of 4096 uint16
  (little endian) in YZX order, i.e. entry `(y * 16 + z) * 16 + x`.
  """
  @spec section_block_types(any, non_neg_integer) :: {:ok, binary} | :error
  def section_block_types(_chunk, _index) do
    # Don't raise here, or Dialyzer complains
    :erlang.nif_error("NIF section_block_types/2 not implemented")
  end
end
