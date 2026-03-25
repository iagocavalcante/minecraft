defmodule Minecraft.Bedrock.Chunk do
  @moduledoc """
  Generates chunks for Bedrock Edition protocol 924.
  SubChunk version 8. Runtime IDs from canonical_block_states.nbt (pmmp bedrock-1.21.80).
  """
  import Bitwise

  # Vanilla runtime IDs (from canonical_block_states.nbt, UseBlockNetworkIDHashes=false)
  @air 12048
  @stone 2437
  @dirt 9413
  @grass_block 10590
  @bedrock 12590

  @doc """
  Generate a flat world chunk: bedrock, stone, dirt, grass.
  4 subchunks + biome data + border byte.
  """
  def flat_chunk do
    sub0 = single_block_subchunk(@bedrock)
    sub1 = single_block_subchunk(@stone)
    sub2 = single_block_subchunk(@stone)
    sub3 = single_block_subchunk(@grass_block)

    biomes = for _ <- 0..23, do: single_palette_storage(1)

    IO.iodata_to_binary([sub0, sub1, sub2, sub3, biomes, <<0>>])
  end

  def test_chunk(runtime_id) do
    subs = for _ <- 1..4, do: single_block_subchunk(runtime_id)
    biomes = for _ <- 0..23, do: single_palette_storage(1)
    IO.iodata_to_binary([subs, biomes, <<0>>])
  end

  defp single_block_subchunk(runtime_id) do
    IO.iodata_to_binary([
      <<8, 1>>,
      single_palette_storage(runtime_id)
    ])
  end

  defp single_palette_storage(id) do
    IO.iodata_to_binary([
      <<1>>,
      encode_varint_signed(1),
      encode_varint_signed(id)
    ])
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
