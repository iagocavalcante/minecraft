defmodule Minecraft.Bedrock.Chunk do
  @moduledoc """
  Network chunk encoding for Bedrock Edition (protocol 1001).

  Layout mirrors dragonfly's network encoding (`server/world/chunk/encode.go`):

    * Each sub-chunk: version byte 9, storage-layer count, y-index byte
      (sub-chunk index + world_range_start >> 4, as an unsigned byte), then one
      paletted storage per layer.
    * Paletted storage header byte = `bits_per_index << 1 | 1` (network flag).
      With a single palette entry, bits_per_index is 0: no index words and no
      palette-length varint are written — only the single entry, as a zigzag
      varint32.
    * After the sub-chunks: one paletted storage per 16-block biome section
      (24 for the overworld's -64..320 range), then a zero byte for border
      blocks.

  Block palette entries are network block hashes (`UseBlockNetworkIDHashes`
  in StartGame is true), so no version-specific runtime-ID table is needed.
  """
  alias Minecraft.Bedrock.BlockHash
  import Bitwise

  # Overworld world range is -64..320: 24 sub-chunks, of which we serialize
  # only the bottom 4 (the flat terrain); the client fills the rest with air.
  @world_range_start -64
  @biome_sections 24
  @plains_biome 1

  @doc """
  Number of serialized sub-chunks `flat_chunk/0` produces — the SubChunkCount
  for the LevelChunk packet.
  """
  def flat_chunk_sub_chunks, do: 4

  @doc """
  Y of the highest solid block surface in the flat chunk (the top face of the
  grass layer). Sub-chunks 0..3 span y -64..-1, so the walkable surface is 0.
  """
  def flat_chunk_surface_y, do: 0

  @doc """
  Generate the LevelChunk raw payload for a flat world chunk: one sub-chunk
  each of bedrock, stone, dirt and grass from the bottom of the world up.
  """
  def flat_chunk do
    blocks = [
      {"minecraft:bedrock", %{"infiniburn_bit" => {:byte, 0}}},
      {"minecraft:stone", %{}},
      {"minecraft:dirt", %{}},
      {"minecraft:grass_block", %{}}
    ]

    sub_chunks =
      blocks
      |> Enum.with_index()
      |> Enum.map(fn {{name, states}, index} ->
        single_block_sub_chunk(index, BlockHash.signed_hash(name, states))
      end)

    biomes = List.duplicate(single_entry_storage(@plains_biome), @biome_sections)

    IO.iodata_to_binary([sub_chunks, biomes, <<0>>])
  end

  defp single_block_sub_chunk(index, palette_entry) do
    y_index = index + (@world_range_start >>> 4)

    [
      # version 9, 1 storage layer, y index (unsigned byte, e.g. -4 -> 252)
      <<9, 1, y_index::8-unsigned>>,
      single_entry_storage(palette_entry)
    ]
  end

  # Paletted storage with bits_per_index = 0: header byte 0x01 (0 <<< 1 ||| 1),
  # then ONLY the single palette entry — no index words, no length prefix.
  defp single_entry_storage(entry) do
    [<<0::7, 1::1>>, encode_varint_signed(entry)]
  end

  defp encode_varint_signed(value) do
    zigzag = if value >= 0, do: value <<< 1, else: (-value <<< 1) - 1
    encode_varuint(zigzag)
  end

  defp encode_varuint(value) when value < 128, do: <<value::8>>

  defp encode_varuint(value) do
    <<1::1, value &&& 0x7F::7, encode_varuint(value >>> 7)::binary>>
  end
end
