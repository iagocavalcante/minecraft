defmodule Minecraft.Bedrock.Chunk do
  @moduledoc """
  Generates minimal flat world chunks for Bedrock Edition protocol 924.
  SubChunk v9 format. Uses vanilla runtime IDs (UseBlockNetworkIDHashes=false).
  """
  import Bitwise

  @doc """
  Generate a flat world chunk payload.
  4 subchunks of solid stone (runtime ID 1) + minimal biome data.
  """
  def flat_chunk do
    # 4 subchunks at y indices 4-7 (y=0..63 with y_offset=-64)
    subs = for i <- 4..7, do: single_block_subchunk(1, i)

    # Biome data: palette-based, one entry per 4x4x4 section
    # Each of 24 vertical sections gets a biome storage
    # Simplest: each section is "0 bits per block, 1 palette entry = plains(1)"
    biomes = for _i <- 0..23, do: single_palette_storage(1)

    IO.iodata_to_binary([subs, biomes])
  end

  # SubChunk with a single block type, v9 format
  defp single_block_subchunk(runtime_id, y_index) do
    IO.iodata_to_binary([
      # version
      <<9>>,
      # 1 storage layer
      <<1>>,
      # y index
      <<y_index::8>>,
      single_palette_storage(runtime_id)
    ])
  end

  # Paletted storage with 1 entry (0 bits per block)
  defp single_palette_storage(id) do
    IO.iodata_to_binary([
      # (bits_per_block << 1) | network_persistence = (0 << 1) | 1 = 1
      <<1>>,
      # palette length (varint32 signed)
      encode_varint_signed(1),
      # palette entry (varint32 signed)
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
