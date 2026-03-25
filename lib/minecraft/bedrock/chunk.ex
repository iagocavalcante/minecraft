defmodule Minecraft.Bedrock.Chunk do
  @moduledoc """
  Generates chunks for Bedrock Edition protocol 924.
  SubChunk version 8. Uses FNV1 block state hashes (UseBlockNetworkIDHashes=true).
  Hashes computed from block name + sorted state properties.
  """
  import Bitwise

  # FNV1-32 hashes of block states (signed int32)
  # These are version-independent — the client maps them to its own block states
  # Runtime IDs from canonical_block_states.nbt (pmmp master/latest)
  @air 12531
  @stone 2533
  @dirt 9853
  @grass_block 11063
  @bedrock 13080

  @doc """
  Generate a flat world chunk.
  """
  def flat_chunk do
    # Test boundary: 50, 63, 64, 127
    sub0 = single_block_subchunk(50)
    sub1 = single_block_subchunk(63)
    sub2 = single_block_subchunk(64)
    sub3 = single_block_subchunk(127)

    biomes = for _ <- 0..23, do: single_palette_storage(1)

    IO.iodata_to_binary([sub0, sub1, sub2, sub3, biomes, <<0>>])
  end

  defp single_block_subchunk(block_hash) do
    IO.iodata_to_binary([
      <<8, 1>>,
      single_palette_storage(block_hash)
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
