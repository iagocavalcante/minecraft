defmodule Minecraft.Bedrock.Chunk do
  @moduledoc """
  Generates chunks for Bedrock Edition.
  SubChunk version 8. UseBlockNetworkIDHashes=false.
  """
  import Bitwise

  # Vanilla runtime IDs from canonical_block_states.nbt
  # Trying dragonfly's latest embedded values
  @air 12_530
  @stone 2_532
  @dirt 9_852
  @grass_block 11_062
  @bedrock 13_079

  @doc """
  Generate a flat world chunk: bedrock, stone, dirt, grass.
  4 subchunks + 24 biome storages + border byte.
  """
  def flat_chunk do
    sub0 = single_block_subchunk(@bedrock)
    sub1 = single_block_subchunk(@stone)
    sub2 = single_block_subchunk(@dirt)
    sub3 = single_block_subchunk(@grass_block)

    biomes = for _ <- 0..23, do: single_palette_storage(1)

    IO.iodata_to_binary([sub0, sub1, sub2, sub3, biomes, <<0>>])
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
