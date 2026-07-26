defmodule Minecraft.Bedrock.Chunk do
  @moduledoc """
  Network chunk encoding for Bedrock Edition (protocol 1001).

  Serializes the NIF-generated world (Java 1.12 block types) into the Bedrock
  wire format, mirroring dragonfly's network encoding
  (`server/world/chunk/encode.go`):

    * Each sub-chunk: version byte 9, storage-layer count, y-index byte (the
      sub-chunk's world Y >> 4 as an unsigned byte), then one paletted storage
      per layer.
    * Paletted storage header byte = `bits_per_index <<< 1 ||| 1` (network
      flag). Indices are packed little-endian into 32-bit words in XZY order
      (`x * 256 + z * 16 + y`); words never span an index. A palette-length
      varint precedes the entries — except for bits_per_index 0 (single-entry
      storage), which writes only the entry itself.
    * After the sub-chunks: one paletted storage per 16-block biome section
      (24 for the overworld's -64..320 range), then a zero byte for border
      blocks.

  Palette entries are network block hashes (`UseBlockNetworkIDHashes` is true
  in StartGame), so no version-specific runtime-ID table is needed.

  The Java world occupies Y 0..255; Bedrock's overworld starts at -64, so four
  all-air sub-chunks are emitted below the generated terrain and Java Y maps
  1:1 onto Bedrock Y.
  """
  alias Minecraft.Bedrock.BlockHash
  import Bitwise
  require Logger

  # Overworld world range is -64..320. The 4 sub-chunks below Java Y=0 are
  # always air; the client fills everything above the serialized sub-chunks
  # with air on its own.
  @world_range_start -64
  @air_sub_chunks_below 4
  @biome_sections 24
  @plains_biome 1

  # Java 1.12 global block IDs (`id <<< 4 ||| meta`, see src/chunk.h) mapped to
  # Bedrock block states. Names and state sets validated against the vanilla
  # block palette (minecraft-data).
  @java_blocks %{
    0 => {"minecraft:air", %{}},
    16 => {"minecraft:stone", %{}},
    32 => {"minecraft:grass_block", %{}},
    48 => {"minecraft:dirt", %{}},
    64 => {"minecraft:cobblestone", %{}},
    112 => {"minecraft:bedrock", %{"infiniburn_bit" => {:byte, 0}}},
    144 => {"minecraft:water", %{"liquid_depth" => {:int, 0}}},
    192 => {"minecraft:sand", %{}},
    208 => {"minecraft:gravel", %{}},
    272 => {"minecraft:oak_log", %{"pillar_axis" => "y"}},
    288 =>
      {"minecraft:oak_leaves", %{"persistent_bit" => {:byte, 0}, "update_bit" => {:byte, 0}}},
    497 => {"minecraft:short_grass", %{}},
    592 => {"minecraft:dandelion", %{}}
  }

  @type_hashes Map.new(@java_blocks, fn {java_type, {name, states}} ->
                 {java_type, BlockHash.signed_hash(name, states)}
               end)
  @air_hash Map.fetch!(@type_hashes, 0)
  @unknown_hash BlockHash.signed_hash("minecraft:unknown", %{})

  # Allowed bits-per-index sizes for paletted storages.
  @palette_sizes [1, 2, 3, 4, 5, 6, 8, 16]

  @doc """
  Encodes a generated world chunk as a LevelChunk raw payload.

  Returns `{sub_chunk_count, payload}` for `Packet.encode_level_chunk/4`.
  """
  @spec encode(Minecraft.Chunk.t()) :: {non_neg_integer, binary}
  def encode(%Minecraft.Chunk{resource: resource} = chunk) do
    num_sections = Minecraft.Chunk.num_sections(chunk)

    java_sections =
      for index <- 0..(num_sections - 1) do
        {:ok, types} = Minecraft.NIF.section_block_types(resource, index)
        encode_sub_chunk(types, index)
      end

    air_below =
      for i <- 0..(@air_sub_chunks_below - 1) do
        sub_chunk_header(i + (@world_range_start >>> 4), [
          single_entry_storage(@air_hash)
        ])
      end

    biomes = List.duplicate(single_entry_storage(@plains_biome), @biome_sections)

    payload = IO.iodata_to_binary([air_below, java_sections, biomes, <<0>>])
    {@air_sub_chunks_below + num_sections, payload}
  end

  @doc """
  The walkable surface Y at local column (x, z) of a chunk — the heightmap
  value, where the generator places the top solid block.
  """
  @spec surface_y(Minecraft.Chunk.t(), 0..15, 0..15) :: non_neg_integer
  def surface_y(%Minecraft.Chunk{resource: resource}, x, z) do
    {:ok, heightmap} = Minecraft.NIF.chunk_heightmap(resource)
    :binary.at(heightmap, z * 16 + x)
  end

  # =====================
  # Sub-chunk encoding
  # =====================

  defp encode_sub_chunk(types_binary, section_index) do
    types = for <<t::16-little <- types_binary>>, do: t
    types_tuple = List.to_tuple(types)

    # Reorder from the generator's YZX layout into Bedrock's XZY layout while
    # building the palette (first-seen order) and per-block palette indices.
    {palette, indices} = palettize(types_tuple)

    storage =
      case palette do
        [only_type] ->
          single_entry_storage(block_hash(only_type))

        _ ->
          packed_storage(palette, indices)
      end

    sub_chunk_header(section_index, [storage])
  end

  defp sub_chunk_header(y_index, storages) do
    [<<9, length(storages), y_index::8-unsigned>>, storages]
  end

  defp palettize(types_tuple) do
    {palette_map, rev_palette, rev_indices} =
      Enum.reduce(bedrock_order(), {%{}, [], []}, fn java_index, {map, rev_pal, rev_idx} ->
        type = elem(types_tuple, java_index)

        case map do
          %{^type => palette_index} ->
            {map, rev_pal, [palette_index | rev_idx]}

          _ ->
            palette_index = map_size(map)
            {Map.put(map, type, palette_index), [type | rev_pal], [palette_index | rev_idx]}
        end
      end)

    _ = palette_map
    {Enum.reverse(rev_palette), Enum.reverse(rev_indices)}
  end

  # Bedrock block order is x outermost, then z, then y; the generator's arrays
  # are y outermost, then z, then x. Precomputed at compile time.
  @bedrock_order for x <- 0..15, z <- 0..15, y <- 0..15, do: (y * 16 + z) * 16 + x
  defp bedrock_order, do: @bedrock_order

  defp packed_storage(palette, indices) do
    bits = Enum.find(@palette_sizes, 16, fn b -> 1 <<< b >= length(palette) end)
    blocks_per_word = div(32, bits)

    words =
      indices
      |> Enum.chunk_every(blocks_per_word)
      |> Enum.map(fn group ->
        word =
          group
          |> Enum.with_index()
          |> Enum.reduce(0, fn {index, pos}, acc -> acc ||| index <<< (bits * pos) end)

        <<word::32-little>>
      end)

    entries = Enum.map(palette, &encode_varint_signed(block_hash(&1)))

    [
      <<bits <<< 1 ||| 1>>,
      words,
      encode_varint_signed(length(palette)),
      entries
    ]
  end

  defp block_hash(java_type) do
    case @type_hashes do
      %{^java_type => hash} ->
        hash

      _ ->
        Logger.warning("Bedrock: no block mapping for Java type #{java_type}")
        @unknown_hash
    end
  end

  # Paletted storage with bits_per_index = 0: header byte 0x01, then ONLY the
  # single palette entry — no index words, no length prefix.
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
