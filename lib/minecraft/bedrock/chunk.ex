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

  @unsigned_hashes Map.new(@java_blocks, fn {java_type, {name, states}} ->
                     {java_type, BlockHash.hash(name, states)}
                   end)
  @java_types_by_hash Map.new(@unsigned_hashes, fn {java_type, hash} -> {hash, java_type} end)

  # Blocks with no obtainable block item (air; water only exists as a bucket).
  @non_item_blocks [0, 144]

  @doc """
  Blocks offered in the creative inventory: `{bedrock_name, signed_hash}`
  pairs, sorted by name. Item names equal block names for all of these.
  """
  @spec creative_blocks() :: [{String.t(), integer}]
  def creative_blocks do
    @java_blocks
    |> Enum.reject(fn {java_type, _} -> java_type in @non_item_blocks end)
    |> Enum.map(fn {java_type, {name, _states}} ->
      {name, Map.fetch!(@type_hashes, java_type)}
    end)
    |> Enum.sort()
  end

  @doc """
  The unsigned network block hash for a mapped Java block type — the runtime
  ID form used by UpdateBlock. Unmapped types resolve to `minecraft:unknown`.
  """
  @spec network_hash(0..0xFFFF) :: 0..0xFFFFFFFF
  def network_hash(java_type) do
    Map.get(@unsigned_hashes, java_type, 0xFFFFFFFE)
  end

  @doc """
  Resolves an unsigned network block hash back to a Java block type, for
  blocks the server knows how to store. Inverse of `network_hash/1`.
  """
  @spec java_type_for_network_hash(0..0xFFFFFFFF) :: {:ok, 0..0xFFFF} | :error
  def java_type_for_network_hash(hash) do
    case @java_types_by_hash do
      %{^hash => java_type} -> {:ok, java_type}
      _ -> :error
    end
  end

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

    biomes = encode_biome_storages(Minecraft.Chunk.get_biome_data(chunk))

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

    # Reorder from the generator's YZX layout into Bedrock's XZY layout, then
    # build the palette (first-seen order) and per-block palette indices.
    values = Enum.map(bedrock_order(), &elem(types_tuple, &1))
    storage = paletted_storage(values, &block_hash/1)

    sub_chunk_header(section_index, [storage])
  end

  # The generator produces one biome per column (256 bytes, indexed z*16+x,
  # legacy numeric biome IDs — the same id space Bedrock's chunk format uses).
  # Bedrock wants a 3D paletted storage per 16-block section; every section
  # gets the same column-extruded storage.
  defp encode_biome_storages(biome_data) do
    columns = List.to_tuple(:binary.bin_to_list(biome_data))

    values =
      for x <- 0..15, z <- 0..15, _y <- 0..15 do
        elem(columns, z * 16 + x)
      end

    # Header 0xFF (0x7F <<< 1 ||| 1) means "same as previous storage"; all our
    # sections share one column-extruded storage, so write it once.
    [paletted_storage(values, & &1) | List.duplicate(<<0xFF>>, @biome_sections - 1)]
  end

  # Builds a network paletted storage from 4096 values in XZY order.
  # `to_entry` converts a raw value into the palette-entry integer (block
  # values become network hashes; biome values are used as-is).
  defp paletted_storage(values, to_entry) do
    {palette, indices} = palettize(values)

    case palette do
      [only_value] ->
        single_entry_storage(to_entry.(only_value))

      _ ->
        packed_storage(Enum.map(palette, to_entry), indices)
    end
  end

  defp sub_chunk_header(y_index, storages) do
    [<<9, length(storages), y_index::8-unsigned>>, storages]
  end

  # Deduplicates a list of values into a first-seen-order palette plus one
  # palette index per value.
  defp palettize(values) do
    {_palette_map, rev_palette, rev_indices} =
      Enum.reduce(values, {%{}, [], []}, fn value, {map, rev_pal, rev_idx} ->
        case map do
          %{^value => palette_index} ->
            {map, rev_pal, [palette_index | rev_idx]}

          _ ->
            palette_index = map_size(map)
            {Map.put(map, value, palette_index), [value | rev_pal], [palette_index | rev_idx]}
        end
      end)

    {Enum.reverse(rev_palette), Enum.reverse(rev_indices)}
  end

  # Bedrock block order is x outermost, then z, then y; the generator's arrays
  # are y outermost, then z, then x. Precomputed at compile time.
  @bedrock_order for x <- 0..15, z <- 0..15, y <- 0..15, do: (y * 16 + z) * 16 + x
  defp bedrock_order, do: @bedrock_order

  defp packed_storage(entries, indices) do
    bits = Enum.find(@palette_sizes, 16, fn b -> 1 <<< b >= length(entries) end)
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

    [
      <<bits <<< 1 ||| 1>>,
      words,
      encode_varint_signed(length(entries)),
      Enum.map(entries, &encode_varint_signed/1)
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
