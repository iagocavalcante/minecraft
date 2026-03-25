defmodule Minecraft.Bedrock.Chunk do
  @moduledoc """
  Generates minimal flat world chunks for Bedrock Edition.

  Bedrock SubChunk format v9:
    - Version byte (9)
    - Storage count (1)
    - Block storage:
      - Palette type byte: (bits_per_block << 1) | network_persistence
      - Block data (padded to 32-bit words)
      - Palette size (varint32)
      - Palette entries (varint32 runtime IDs)
  """
  import Bitwise

  # Runtime block IDs for Bedrock (these are network runtime IDs, not block state IDs)
  # Using simple placeholder IDs — real servers send a block palette in StartGame
  @air 0
  @bedrock 11
  @stone 1
  @dirt 10
  @grass_block 8

  @doc """
  Generate a flat world chunk: bedrock at y=0, stone y=1-62, dirt y=63, grass at y=64, air above.
  Returns binary chunk data (4 subchunks).
  """
  def flat_chunk do
    sub0 = flat_subchunk(0)
    sub1 = flat_subchunk(1)
    sub2 = flat_subchunk(2)
    sub3 = flat_subchunk(3)

    IO.iodata_to_binary([sub0, sub1, sub2, sub3])
  end

  # SubChunk 0: y=0-15, bedrock at 0, stone at 1-15
  # SubChunk 1: y=16-31, all stone
  # SubChunk 2: y=32-47, all stone
  # SubChunk 3: y=48-63, stone at 48-62, dirt at 63, grass at 64 (y=0 in subchunk 4)
  # For simplicity, subchunk 3 has stone 0-14, dirt at 15

  defp flat_subchunk(0) do
    # y=0 bedrock, y=1-15 stone
    blocks =
      for y <- 0..15, _z <- 0..15, _x <- 0..15 do
        if y == 0, do: @bedrock, else: @stone
      end

    encode_subchunk(blocks)
  end

  defp flat_subchunk(sub) when sub in [1, 2] do
    # All stone
    blocks = List.duplicate(@stone, 4096)
    encode_subchunk(blocks)
  end

  defp flat_subchunk(3) do
    # y=48-62 (sub-y 0-14) stone, y=63 (sub-y 15) grass_block
    blocks =
      for y <- 0..15, _z <- 0..15, _x <- 0..15 do
        cond do
          y < 15 -> @dirt
          y == 15 -> @grass_block
          true -> @air
        end
      end

    encode_subchunk(blocks)
  end

  defp encode_subchunk(blocks) do
    # Get unique palette
    palette = blocks |> Enum.uniq() |> Enum.sort()
    palette_map = palette |> Enum.with_index() |> Map.new()

    # Determine bits per block
    palette_size = length(palette)
    bits_per_block = max(1, ceil_log2(palette_size))
    # Bedrock requires specific bit sizes: 1, 2, 3, 4, 5, 6, 8, 16
    bits_per_block = normalize_bits(bits_per_block)

    # Encode block indices
    indices = Enum.map(blocks, fn b -> Map.fetch!(palette_map, b) end)
    block_data = pack_indices(indices, bits_per_block)

    # Encode palette
    palette_data =
      Enum.map(palette, fn id ->
        encode_varint_signed(id)
      end)
      |> IO.iodata_to_binary()

    palette_size_encoded = encode_varint_signed(palette_size)

    # SubChunk v9 format
    IO.iodata_to_binary([
      <<9>>,
      <<1>>,
      <<bits_per_block <<< 1 ||| 1>>,
      block_data,
      palette_size_encoded,
      palette_data
    ])
  end

  defp pack_indices(indices, bits_per_block) do
    blocks_per_word = div(32, bits_per_block)
    words_needed = div(4096 + blocks_per_word - 1, blocks_per_word)

    indices
    |> Enum.chunk_every(blocks_per_word, blocks_per_word, Stream.repeatedly(fn -> 0 end))
    |> Enum.take(words_needed)
    |> Enum.map(fn chunk ->
      word =
        chunk
        |> Enum.with_index()
        |> Enum.reduce(0, fn {val, idx}, acc ->
          acc ||| val <<< (idx * bits_per_block)
        end)

      <<word::32-little>>
    end)
    |> IO.iodata_to_binary()
  end

  defp normalize_bits(b) when b <= 1, do: 1
  defp normalize_bits(b) when b <= 2, do: 2
  defp normalize_bits(b) when b <= 3, do: 3
  defp normalize_bits(b) when b <= 4, do: 4
  defp normalize_bits(b) when b <= 5, do: 5
  defp normalize_bits(b) when b <= 6, do: 6
  defp normalize_bits(b) when b <= 8, do: 8
  defp normalize_bits(_), do: 16

  defp ceil_log2(1), do: 1
  defp ceil_log2(n), do: ceil(:math.log2(n)) |> trunc()

  defp encode_varint_signed(value) do
    zigzag = if value >= 0, do: value <<< 1, else: (-value <<< 1) - 1
    encode_varuint(zigzag)
  end

  defp encode_varuint(value) when value < 128, do: <<value::8>>

  defp encode_varuint(value) do
    <<1::1, value &&& 0x7F::7, encode_varuint(value >>> 7)::binary>>
  end
end
