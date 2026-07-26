defmodule Minecraft.Bedrock.Packet do
  @moduledoc """
  Bedrock Edition game packet encoder/decoder.
  Only the minimum packets needed for offline login + spawn.
  """
  alias Minecraft.Bedrock.Codec
  import Bitwise

  # --- Packet IDs ---
  @login 0x01
  @play_status 0x02
  @resource_packs_info 0x06
  @resource_pack_stack 0x07
  @resource_pack_client_response 0x08
  @start_game 0x0B
  @update_block 0x15
  @inventory_transaction 0x1E
  @interact 0x21
  @container_open 0x2E
  @container_close 0x2F
  @inventory_content 0x31
  @request_chunk_radius 0x45
  @chunk_radius_updated 0x46
  @level_chunk 0x3A
  @set_local_player_as_initialised 0x71
  @network_chunk_publisher_update 0x79
  @network_settings 0x8F
  @player_auth_input 0x90
  @request_network_settings 0xC1

  # =====================
  # SERVER → CLIENT
  # =====================

  @doc "NetworkSettings — sent first, enables compression"
  def encode_network_settings(compression_threshold \\ 256) do
    body = <<
      compression_threshold::16-little,
      0::16-little,
      0::8,
      0::8,
      0.0::32-little-float
    >>

    wrap(@network_settings, body)
  end

  @doc "PlayStatus — login result or player spawn signal"
  def encode_play_status(status) do
    code =
      case status do
        :login_success -> 0
        :failed_client_old -> 1
        :failed_server_old -> 2
        :player_spawn -> 3
        :failed_invalid_tenant -> 4
        :failed_vanilla_edu -> 5
        :failed_edu_vanilla -> 6
        :failed_server_full -> 7
      end

    wrap(@play_status, <<code::32>>)
  end

  @doc "ResourcePacksInfo — no packs (protocol 924)"
  def encode_resource_packs_info do
    body =
      IO.iodata_to_binary([
        # must_accept (bool)
        <<0::8>>,
        # has_addons (bool)
        <<0::8>>,
        # has_scripts (bool)
        <<0::8>>,
        # disable_vibrant_visuals (bool) — added in newer protocols
        <<0::8>>,
        # world_template UUID (16 bytes zeros)
        <<0::128>>,
        # world_template version (empty string, varint length 0)
        <<0>>,
        # texture_packs count (li16 = 0)
        <<0::16-little>>
      ])

    wrap(@resource_packs_info, body)
  end

  @doc "ResourcePackStack — no packs (protocol 924, matches gophertunnel)"
  def encode_resource_pack_stack do
    body =
      IO.iodata_to_binary([
        # TexturePackRequired (bool)
        <<0::8>>,
        # TexturePacks (Slice — varuint32 length = 0)
        encode_varint_unsigned(0),
        # BaseGameVersion (string)
        encode_string("*"),
        # Experiments (SliceUint32Length — uint32 LE length = 0)
        <<0::32-little>>,
        # ExperimentsPreviouslyToggled (bool)
        <<0::8>>,
        # IncludeEditorPacks (bool)
        <<0::8>>
      ])

    wrap(@resource_pack_stack, body)
  end

  @doc "ChunkRadiusUpdated — confirm chunk radius"
  def encode_chunk_radius_updated(radius) do
    wrap(@chunk_radius_updated, encode_varint_signed(radius))
  end

  @doc "NetworkChunkPublisherUpdate — tell client chunks are available"
  def encode_network_chunk_publisher_update(x, y, z, radius) do
    body = <<
      # Position (BlockPos — 3x varint32 zigzag)
      encode_varint_signed(x)::binary,
      encode_varint_signed(y)::binary,
      encode_varint_signed(z)::binary,
      encode_varint_unsigned(radius)::binary,
      0::32-little
    >>

    wrap(@network_chunk_publisher_update, body)
  end

  @doc """
  UpdateBlock — replace one block client-side. `block_runtime_id` is the
  unsigned network block hash of the new block.
  """
  def encode_update_block(x, y, z, block_runtime_id) do
    body =
      IO.iodata_to_binary([
        # Position (BlockPos — 3x varint32 zigzag)
        encode_varint_signed(x),
        encode_varint_signed(y),
        encode_varint_signed(z),
        # NewBlockRuntimeID (varuint32)
        encode_varint_unsigned(block_runtime_id),
        # Flags (varuint32) — Neighbours ||| Network
        encode_varint_unsigned(0b11),
        # Layer (varuint32)
        encode_varint_unsigned(0)
      ])

    wrap(@update_block, body)
  end

  @doc "LevelChunk — send chunk data to client (protocol 924)"
  def encode_level_chunk(x, z, sub_chunk_count, raw_payload) do
    body =
      IO.iodata_to_binary([
        # ChunkPos (2x varint32 zigzag)
        encode_varint_signed(x),
        encode_varint_signed(z),
        # Dimension (varint32)
        encode_varint_signed(0),
        # SubChunkCount (varuint32)
        encode_varint_unsigned(sub_chunk_count),
        # CacheEnabled (bool)
        <<0::8>>,
        # RawPayload (ByteSlice — varuint32 length + data)
        encode_varint_unsigned(byte_size(raw_payload)),
        raw_payload
      ])

    wrap(@level_chunk, body)
  end

  @doc """
  StartGame — matches gophertunnel Marshal order for protocol 1001 (1.26.30).
  """
  def encode_start_game(opts \\ []) do
    entity_id = Keyword.get(opts, :entity_id, 1)
    runtime_id = Keyword.get(opts, :runtime_id, 1)
    game_mode = Keyword.get(opts, :game_mode, 1)
    {px, py, pz} = Keyword.get(opts, :position, {0.0, 64.0, 0.0})
    {spx, spy, spz} = Keyword.get(opts, :spawn, {0, 64, 0})
    world_name = Keyword.get(opts, :world_name, "Elixir Minecraft")

    body =
      IO.iodata_to_binary([
        # EntityUniqueID
        encode_varint_signed64(entity_id),
        # EntityRuntimeID
        encode_varint_unsigned64(runtime_id),
        # PlayerGameMode
        encode_varint_signed(game_mode),
        # PlayerPosition
        <<px::32-little-float, py::32-little-float, pz::32-little-float>>,
        # Pitch, Yaw
        <<0.0::32-little-float, 0.0::32-little-float>>,
        # WorldSeed (int64)
        <<0::64-little>>,
        # SpawnBiomeType (int16)
        <<0::16-little>>,
        # UserDefinedBiomeName
        encode_string(""),
        # Dimension (overworld)
        encode_varint_signed(0),
        # Generator (flat)
        encode_varint_signed(2),
        # WorldGameMode
        encode_varint_signed(game_mode),
        # Hardcore
        <<0::8>>,
        # Difficulty (easy)
        encode_varint_signed(1),
        # WorldSpawn (BlockPos — 3x varint32 zigzag)
        encode_varint_signed(spx),
        encode_varint_signed(spy),
        encode_varint_signed(spz),
        # AchievementsDisabled (false!)
        <<0::8>>,
        # EditorWorldType
        encode_varint_signed(0),
        # CreatedInEditor
        <<0::8>>,
        # ExportedFromEditor
        <<0::8>>,
        # DayCycleLockTime
        encode_varint_signed(0),
        # EducationEditionOffer
        encode_varint_signed(0),
        # EducationFeaturesEnabled
        <<0::8>>,
        # EducationProductID
        encode_string(""),
        # RainLevel
        <<0.0::32-little-float>>,
        # LightningLevel
        <<0.0::32-little-float>>,
        # ConfirmedPlatformLockedContent
        <<0::8>>,
        # MultiPlayerGame
        <<1::8>>,
        # LANBroadcastEnabled
        <<1::8>>,
        # XBLBroadcastMode
        encode_varint_signed(4),
        # PlatformBroadcastMode
        encode_varint_signed(4),
        # CommandsEnabled
        <<1::8>>,
        # TexturePackRequired
        <<0::8>>,
        # GameRules (FuncSlice, 0 rules)
        encode_varint_unsigned(0),
        # Experiments (SliceUint32Length, 0)
        <<0::32-little>>,
        # ExperimentsPreviouslyToggled
        <<0::8>>,
        # BonusChestEnabled
        <<0::8>>,
        # StartWithMapEnabled
        <<0::8>>,
        # PlayerPermissions (member)
        encode_varint_signed(1),
        # ServerChunkTickRadius (int32)
        <<4::32-little-signed>>,
        # HasLockedBehaviourPack
        <<0::8>>,
        # HasLockedTexturePack
        <<0::8>>,
        # FromLockedWorldTemplate
        <<0::8>>,
        # MSAGamerTagsOnly
        <<0::8>>,
        # FromWorldTemplate
        <<0::8>>,
        # WorldTemplateSettingsLocked
        <<0::8>>,
        # OnlySpawnV1Villagers
        <<0::8>>,
        # PersonaDisabled
        <<0::8>>,
        # CustomSkinsDisabled
        <<0::8>>,
        # EmoteChatMuted
        <<0::8>>,
        # BaseGameVersion
        encode_string("*"),
        # LimitedWorldWidth
        <<0::32-little>>,
        # LimitedWorldDepth
        <<0::32-little>>,
        # NewNether
        <<1::8>>,
        # EducationSharedResourceURI (buttonName + linkURI)
        encode_string(""),
        encode_string(""),
        # ForceExperimentalGameplay
        <<0::8>>,
        # ChatRestrictionLevel (uint8)
        <<0::8>>,
        # DisablePlayerInteractions
        <<0::8>>,
        # ServerEditorConnectionPolicy (present at protocol 1001)
        encode_varint_signed(0),
        # AllowAnonymousBlockDropsInEditorWorlds (present at protocol 1001)
        <<0::8>>,
        # LevelID
        encode_string(""),
        # WorldName
        encode_string(world_name),
        # TemplateContentIdentity
        encode_string(""),
        # Trial
        <<0::8>>,
        # PlayerMovementSettings (only 2 fields in protocol 924)
        # RewindHistorySize
        encode_varint_signed(0),
        # ServerAuthoritativeBlockBreaking
        <<0::8>>,
        # Time (int64)
        <<0::64-little>>,
        # EnchantmentSeed
        encode_varint_signed(0),
        # Blocks (Slice, empty — client uses its own vanilla palette)
        encode_varint_unsigned(0),
        # MultiPlayerCorrelationID
        encode_string(""),
        # ServerAuthoritativeInventory
        <<0::8>>,
        # GameVersion
        encode_string("1.26.30"),
        # PropertyData — empty NBT compound (NetworkLittleEndian)
        # TAG_Compound(0x0A) + varint name_len(0) + TAG_End(0x00)
        <<0x0A, 0x00, 0x00>>,
        # ServerBlockStateChecksum (uint64)
        <<0::64-little>>,
        # WorldTemplateID (UUID, 16 bytes)
        <<0::128>>,
        # ClientSideGeneration
        <<0::8>>,
        # UseBlockNetworkIDHashes (true — palette entries are FNV-1a hashes of
        # the block state NBT, see Minecraft.Bedrock.BlockHash; no
        # version-specific runtime-ID table needed)
        <<1::8>>,
        # ServerAuthoritativeSound
        <<0::8>>,
        # IsLoggingChat (present at protocol 1001)
        <<0::8>>,
        # ServerJoinInformation (OptionalMarshaler — write false/0 to skip)
        <<0::8>>,
        # ServerID
        encode_string(""),
        # ScenarioID
        encode_string(""),
        # WorldID
        encode_string(""),
        # OwnerID
        encode_string("")
      ])

    wrap(@start_game, body)
  end

  # =====================
  # CLIENT → SERVER (decode only)
  # =====================

  @doc "Decode a game packet by ID"
  def decode(packet_data) do
    require Logger
    {packet_id, rest} = Codec.decode_varuint(packet_data)
    Logger.debug("Bedrock pkt id=#{packet_id}")
    decode_by_id(packet_id, rest)
  end

  defp decode_by_id(@request_network_settings, <<protocol::32, _::binary>>) do
    {:request_network_settings, %{protocol_version: protocol}}
  end

  defp decode_by_id(@login, <<protocol::32, rest::binary>>) do
    # Connection request is length-prefixed
    {_len, jwt_data} = Codec.decode_varuint(rest)
    # Parse the chain length + chain JSON
    <<chain_len::32-little, chain_json::binary-size(chain_len), rest::binary>> = jwt_data

    # Extract player name from the JWT chain
    player_name = extract_player_name(chain_json)

    # Parse client data JWT length + JWT
    <<_client_data_len::32-little, _client_data_jwt::binary>> = rest

    {:login, %{protocol_version: protocol, player_name: player_name}}
  end

  defp decode_by_id(@resource_pack_client_response, rest) do
    {status, _rest} = Codec.decode_varuint(rest)

    status_atom =
      case status do
        1 -> :refused
        2 -> :send_packs
        3 -> :have_all_packs
        4 -> :completed
        _ -> :unknown
      end

    {:resource_pack_client_response, %{status: status_atom}}
  end

  defp decode_by_id(@request_chunk_radius, rest) do
    {radius, _rest} = decode_varint_signed_raw(rest)
    {:request_chunk_radius, %{radius: radius}}
  end

  defp decode_by_id(@set_local_player_as_initialised, _rest) do
    {:set_local_player_as_initialised, %{}}
  end

  # PlayerAuthInput InputData bitset flags (bit numbers).
  @input_flag_perform_item_interaction 34
  @input_flag_perform_block_actions 35
  @input_flag_perform_item_stack_request 36

  # PlayerBlockAction actions that carry a block position + face:
  # StartBreak, AbortBreak, CrackBreak, PredictDestroyBlock, ContinueDestroyBlock.
  @block_actions_with_position [0, 1, 18, 26, 27]

  # PlayerAuthInput — sent ~20/s by the client. Carries position/rotation
  # always, and (gated by InputData bits) the block actions used for
  # server-authoritative block breaking, which modern clients use regardless
  # of the ServerAuthoritativeBlockBreaking setting in StartGame.
  defp decode_by_id(@player_auth_input, rest) do
    <<pitch::32-little-float, yaw::32-little-float, px::32-little-float, py::32-little-float,
      pz::32-little-float, _move_vec::binary-size(8), head_yaw::32-little-float, rest::binary>> =
      rest

    # InputData is a bitset marshaled as one unbounded LEB128 varint.
    {input_data, rest} = Codec.decode_varuint(rest)
    {_input_mode, rest} = Codec.decode_varuint(rest)
    {_play_mode, rest} = Codec.decode_varuint(rest)
    {_interaction_model, rest} = Codec.decode_varuint(rest)
    <<_interact_pitch::32-little-float, _interact_yaw::32-little-float, rest::binary>> = rest
    {tick, rest} = Codec.decode_varuint(rest)
    <<_delta::binary-size(12), rest::binary>> = rest

    base = %{position: {px, py, pz}, pitch: pitch, yaw: yaw, head_yaw: head_yaw, tick: tick}

    {:player_auth_input, Map.merge(base, decode_auth_input_conditionals(input_data, rest))}
  end

  # InventoryTransaction — carries block breaking/placing in client-authoritative
  # mode (ServerAuthoritativeBlockBreaking is false in StartGame).
  defp decode_by_id(@inventory_transaction, rest) do
    {_legacy_request_id, rest} = decode_varint_signed_raw(rest)
    <<has_legacy::8, rest::binary>> = rest
    rest = if has_legacy == 0, do: rest, else: skip_legacy_set_item_slots(rest)
    <<has_type::8, rest::binary>> = rest

    {transaction_type, rest} =
      if has_type == 0, do: {:none, rest}, else: Codec.decode_varuint(rest)

    <<has_actions::8, rest::binary>> = rest

    rest =
      if has_actions == 0 do
        rest
      else
        {action_count, rest} = Codec.decode_varuint(rest)
        Enum.reduce(1..action_count//1, rest, fn _, r -> skip_inventory_action(r) end)
      end

    # 2 = UseItem — the only transaction type acted on.
    if transaction_type == 2 do
      {action_type, rest} = decode_varint_signed_raw(rest)
      <<_trigger_type::8, rest::binary>> = rest
      {bx, rest} = decode_varint_signed_raw(rest)
      {by, rest} = decode_varint_signed_raw(rest)
      {bz, rest} = decode_varint_signed_raw(rest)
      <<face::8, rest::binary>> = rest
      {_hotbar_slot, rest} = decode_varint_signed_raw(rest)
      held_block_runtime_id = parse_held_block_runtime_id(rest)

      action =
        case action_type do
          0 -> :click_block
          1 -> :click_air
          2 -> :break_block
          3 -> :use_as_attack
          other -> {:unknown, other}
        end

      {:inventory_transaction,
       %{
         type: :use_item,
         action: action,
         block_position: {bx, by, bz},
         face: face,
         held_block_runtime_id: held_block_runtime_id
       }}
    else
      {:inventory_transaction, %{type: transaction_type}}
    end
  end

  # ClientCacheStatus (0x81 = 129) — client tells us if it supports blob cache
  defp decode_by_id(0x81, <<supported::8, _rest::binary>>) do
    {:client_cache_status, %{supported: supported != 0}}
  end

  # Interact — action 6 (OpenInventory) is the client asking to open its own
  # inventory; the server must answer with ContainerOpen.
  defp decode_by_id(@interact, <<action::8, rest::binary>>) do
    {_target_runtime_id, _rest} = Codec.decode_varuint(rest)

    action_atom =
      case action do
        6 -> :open_inventory
        other -> {:other, other}
      end

    {:interact, %{action: action_atom}}
  end

  defp decode_by_id(@container_close, <<window_id::8, container_type::8, _server::8>>) do
    {:container_close, %{window_id: window_id, container_type: container_type}}
  end

  defp decode_by_id(id, _rest) do
    {:unknown_bedrock_packet, id}
  end

  # =====================
  # PRIVATE HELPERS
  # =====================

  @item_registry 162
  @creative_content 145

  # An empty ItemInstance (ItemInstanceNew wire format): int16 network ID 0,
  # uint16 count 0, varuint metadata 0, no stack-net-ID, varuint block runtime
  # ID 0, empty extra-data byte slice.
  @empty_item_instance <<0, 0, 0, 0, 0, 0, 0, 0>>

  @doc """
  InventoryContent (ID 49) — a full (empty) inventory window snapshot. The
  client refuses to open its inventory UI until it has received the initial
  content for the player windows.
  """
  def encode_inventory_content(window_id, slot_count) do
    body =
      IO.iodata_to_binary([
        encode_varint_unsigned(window_id),
        encode_varint_unsigned(slot_count),
        List.duplicate(@empty_item_instance, slot_count),
        # FullContainerName: container ID 0, dynamic container ID absent
        <<0, 0>>,
        # StorageItem (only meaningful for dynamic containers)
        @empty_item_instance
      ])

    wrap(@inventory_content, body)
  end

  @doc """
  ContainerOpen (ID 46) — server's answer to Interact(OpenInventory); without
  it the inventory button does nothing. Container type 0xFF (-1) is the
  player's own inventory.
  """
  def encode_container_open(window_id, container_type, {x, y, z}, entity_unique_id) do
    body =
      IO.iodata_to_binary([
        <<window_id::8, container_type::8>>,
        encode_varint_signed(x),
        encode_varint_signed(y),
        encode_varint_signed(z),
        encode_varint_signed64(entity_unique_id)
      ])

    wrap(@container_open, body)
  end

  @doc """
  ContainerClose (ID 47) — echoed back when the client reports closing a
  window (the client expects the ack; `server_side?` is false for that case).
  """
  def encode_container_close(window_id, container_type, server_side?) do
    server = if server_side?, do: 1, else: 0
    wrap(@container_close, <<window_id::8, container_type::8, server::8>>)
  end

  # Empty NBT compound, NetworkLittleEndian: TAG_Compound + empty name + TAG_End.
  @empty_nbt <<0x0A, 0x00, 0x00>>

  @doc """
  ItemRegistry (ID 162) — the full vanilla item table, sent right after
  StartGame. Each entry: name, runtime ID (int16 LE, signed — block items are
  negative), component-based bool, version (zigzag varint), NBT data.
  """
  def encode_item_registry(items) do
    entries =
      Enum.map(items, fn %{name: name, runtime_id: runtime_id, version: version} ->
        [
          encode_string(name),
          <<runtime_id::16-little-signed>>,
          # ComponentBased (vanilla items are not)
          <<0::8>>,
          encode_varint_signed(version),
          @empty_nbt
        ]
      end)

    body = IO.iodata_to_binary([encode_varint_unsigned(length(items)), entries])
    wrap(@item_registry, body)
  end

  @doc """
  CreativeContent (ID 145) — the creative inventory. `groups` are
  `{category, name, icon_stack}` tuples; `items` are `{item_stack, group_index}`
  tuples, numbered 1..n as their creative network IDs. Stacks are
  `{item_runtime_id, block_runtime_id}` (signed network block hash, 0 for
  non-block items).
  """
  def encode_creative_content(groups, items) do
    group_entries =
      Enum.map(groups, fn {category, name, icon_stack} ->
        [<<category::32-little-signed>>, encode_string(name), encode_item_stack(icon_stack)]
      end)

    item_entries =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {{stack, group_index}, creative_network_id} ->
        [
          encode_varint_unsigned(creative_network_id),
          encode_item_stack(stack),
          encode_varint_unsigned(group_index)
        ]
      end)

    body =
      IO.iodata_to_binary([
        encode_varint_unsigned(length(groups)),
        group_entries,
        encode_varint_unsigned(length(items)),
        item_entries
      ])

    wrap(@creative_content, body)
  end

  # ItemStack (gophertunnel Writer.Item): zigzag network ID (0 ends the stack),
  # count, metadata, zigzag block runtime ID, then the extra-data blob as a
  # varuint byte slice: int16 NBT length (0 = none) + two empty uint32-length
  # string lists (CanBePlacedOn / CanBreak).
  defp encode_item_stack({item_runtime_id, block_runtime_id}) do
    if item_runtime_id == 0 do
      encode_varint_signed(0)
    else
      extra = <<0::16-little, 0::32-little, 0::32-little>>

      IO.iodata_to_binary([
        encode_varint_signed(item_runtime_id),
        # Count (uint16 LE)
        <<1::16-little>>,
        # MetadataValue (varuint)
        encode_varint_unsigned(0),
        encode_varint_signed(block_runtime_id),
        encode_varint_unsigned(byte_size(extra)),
        extra
      ])
    end
  end

  # Block palette for StartGame — defines runtime ID to block name mapping
  # Each entry: string(name) + NBT(properties as NetworkLittleEndian compound)
  # Runtime ID = index in this list
  defp encode_block_palette do
    blocks = [
      "minecraft:air",
      "minecraft:stone",
      "minecraft:dirt",
      "minecraft:grass_block",
      "minecraft:bedrock"
    ]

    entries =
      Enum.map(blocks, fn name ->
        IO.iodata_to_binary([
          encode_string(name),
          # Empty NBT compound (NetworkLittleEndian): TAG_Compound + varint name_len(0) + TAG_End
          <<0x0A, 0x00, 0x00>>
        ])
      end)
      |> IO.iodata_to_binary()

    IO.iodata_to_binary([
      encode_varint_unsigned(length(blocks)),
      entries
    ])
  end

  defp wrap(packet_id, body) do
    # Bedrock uses raw varuint packet ID (no << 2 shift in practice)
    header = Codec.encode_varuint(packet_id)
    <<header::binary, body::binary>>
  end

  defp encode_level_settings(spx, spy, spz, game_mode, _world_name) do
    IO.iodata_to_binary([
      # Seed
      <<0::64-little>>,
      # SpawnBiomeType
      encode_varint_signed(0),
      # UserDefinedBiomeName
      encode_string(""),
      # Dimension
      encode_varint_signed(0),
      # Generator
      encode_varint_signed(2),
      # WorldGameMode
      encode_varint_signed(game_mode),
      # IsHardcore
      <<0::8>>,
      # Difficulty
      encode_varint_signed(1),
      # DefaultSpawn (block position — varint signed x, varint unsigned y, varint signed z)
      encode_varint_signed(spx),
      encode_varint_unsigned(spy),
      encode_varint_signed(spz),
      # AchievementsDisabled
      <<1::8>>,
      # EditorWorldType
      encode_varint_signed(0),
      # CreatedInEditor
      <<0::8>>,
      # ExportedFromEditor
      <<0::8>>,
      # DayCycleStopTime
      encode_varint_signed(6000),
      # EduOffer
      encode_varint_signed(0),
      # EduFeaturesEnabled
      <<0::8>>,
      # EduProductUUID
      encode_string(""),
      # RainLevel
      <<0.0::32-little-float>>,
      # LightningLevel
      <<0.0::32-little-float>>,
      # HasConfirmedPlatformLockedContent
      <<0::8>>,
      # IsMultiplayerGame
      <<1::8>>,
      # BroadcastToLAN
      <<1::8>>,
      # XBoxLiveBroadcastMode
      encode_varint_unsigned(4),
      # PlatformBroadcastMode
      encode_varint_unsigned(4),
      # CommandsEnabled
      <<1::8>>,
      # IsTexturePackRequired
      <<0::8>>,
      # GameRules (empty)
      encode_varint_unsigned(0),
      # Experiments (empty)
      <<0::32-little, 0::8>>,
      # BonusChestEnabled
      <<0::8>>,
      # MapEnabled
      <<0::8>>,
      # PermissionLevel
      encode_varint_signed(1),
      # ServerChunkTickRange
      <<4::32-little>>,
      # HasLockedBehaviorPack
      <<0::8>>,
      # HasLockedResourcePack
      <<0::8>>,
      # IsFromLockedWorldTemplate
      <<0::8>>,
      # MSAGamertagsOnly
      <<0::8>>,
      # IsFromWorldTemplate
      <<0::8>>,
      # IsWorldTemplateOptionLocked
      <<0::8>>,
      # OnlySpawnV1Villagers
      <<0::8>>,
      # PersonaDisabled
      <<0::8>>,
      # CustomSkinsDisabled
      <<0::8>>,
      # EmoteChatMuted
      <<0::8>>,
      # BaseGameVersion
      encode_string("*"),
      # LimitedWorldWidth
      <<0::32-little>>,
      # LimitedWorldLength
      <<0::32-little>>,
      # IsNewNether
      <<1::8>>,
      # EduResourceURI (empty)
      encode_string(""),
      encode_string(""),
      # ExperimentalGameplayOverride
      <<0::8>>,
      # ChatRestrictionLevel
      <<0::8>>,
      # DisablePlayerInteractions
      <<0::8>>,
      # ServerIdentifier
      encode_string(""),
      # WorldIdentifier
      encode_string(""),
      # ScenarioIdentifier
      encode_string("")
    ])
  end

  # --- String encoding (Bedrock uses unsigned varint length prefix) ---

  defp encode_string(str) do
    <<Codec.encode_varuint(byte_size(str))::binary, str::binary>>
  end

  # --- VarInt encoding (signed = zigzag, unsigned = raw LEB128) ---

  defp encode_varint_signed(value) do
    zigzag = if value >= 0, do: value <<< 1, else: (-value <<< 1) - 1
    Codec.encode_varuint(zigzag)
  end

  defp encode_varint_unsigned(value), do: Codec.encode_varuint(value)

  defp encode_varint_signed64(value) do
    zigzag = if value >= 0, do: value <<< 1, else: (-value <<< 1) - 1
    Codec.encode_varuint(zigzag)
  end

  defp encode_varint_unsigned64(value), do: Codec.encode_varuint(value)

  # Parses the flag-gated tail of PlayerAuthInput. Marshal order after Delta:
  # ItemInteraction (bit 34), ItemStackRequest (bit 36, encoded between 34 and
  # 35 per struct order in gophertunnel), BlockActions (bit 35). An
  # ItemStackRequest cannot be skipped safely, so when present the rest of the
  # tail is dropped for that tick (movement data is already extracted).
  defp decode_auth_input_conditionals(input_data, rest) do
    require Logger

    {item_interaction, rest} =
      if bit_set?(input_data, @input_flag_perform_item_interaction) do
        decode_player_inventory_action(rest)
      else
        {nil, rest}
      end

    cond do
      rest == :parse_failed ->
        %{item_interaction: nil, block_actions: []}

      bit_set?(input_data, @input_flag_perform_item_stack_request) ->
        if bit_set?(input_data, @input_flag_perform_block_actions) do
          Logger.debug(
            "Bedrock: PlayerAuthInput with ItemStackRequest — block actions dropped this tick"
          )
        end

        %{item_interaction: item_interaction, block_actions: []}

      bit_set?(input_data, @input_flag_perform_block_actions) ->
        {actions, _rest} = decode_block_actions(rest)
        %{item_interaction: item_interaction, block_actions: actions}

      true ->
        %{item_interaction: item_interaction, block_actions: []}
    end
  end

  # PlayerInventoryAction (PlayerAuthInput bit 34) — an inline UseItem
  # transaction in the OLD wire formats (varuint action/trigger, varint face,
  # legacy item encoding), per gophertunnel Reader.PlayerInventoryAction.
  # Only the fields needed for block placement are extracted; a parse failure
  # drops the rest of the tail for this tick.
  defp decode_player_inventory_action(data) do
    {legacy_request_id, rest} = decode_varint_signed_raw(data)

    rest =
      if legacy_request_id < -1 and (legacy_request_id &&& 1) == 0 do
        skip_legacy_set_item_slots(rest)
      else
        rest
      end

    {action_count, rest} = Codec.decode_varuint(rest)
    rest = Enum.reduce(1..action_count//1, rest, fn _, r -> skip_inventory_action_old(r) end)
    {action_type, rest} = Codec.decode_varuint(rest)
    {_trigger_type, rest} = Codec.decode_varuint(rest)
    {bx, rest} = decode_varint_signed_raw(rest)
    {by, rest} = decode_varint_signed_raw(rest)
    {bz, rest} = decode_varint_signed_raw(rest)
    {face, rest} = decode_varint_signed_raw(rest)
    {_hotbar_slot, rest} = decode_varint_signed_raw(rest)
    {held_block_runtime_id, rest} = skip_item_instance_legacy(rest)
    <<_player_pos::binary-size(12), _clicked_pos::binary-size(12), rest::binary>> = rest
    {_block_runtime_id, rest} = Codec.decode_varuint(rest)

    {%{
       action_type: action_type,
       block_position: {bx, by, bz},
       face: face,
       held_block_runtime_id: held_block_runtime_id
     }, rest}
  rescue
    _ -> {nil, :parse_failed}
  end

  # Old-format InventoryAction (no presence bools around window ID / flags).
  defp skip_inventory_action_old(data) do
    {source_type, rest} = Codec.decode_varuint(data)

    rest =
      case source_type do
        # 0 = container, 100 = TODO/crafting: varint window ID
        s when s in [0, 100] ->
          {_window_id, r} = decode_varint_signed_raw(rest)
          r

        # 2 = world interaction: varuint flags
        2 ->
          {_flags, r} = Codec.decode_varuint(rest)
          r

        _ ->
          rest
      end

    {_inventory_slot, rest} = Codec.decode_varuint(rest)
    {_old_id, rest} = skip_item_instance_legacy(rest)
    {_new_id, rest} = skip_item_instance_legacy(rest)
    rest
  end

  # SliceVarint32Length of PlayerBlockAction: zigzag count, then per action a
  # zigzag action ID plus BlockPos + zigzag face for position-carrying actions.
  defp decode_block_actions(data) do
    {count, rest} = decode_varint_signed_raw(data)

    {actions, rest} =
      Enum.reduce(1..count//1, {[], rest}, fn _, {acc, r} ->
        {action, r} = decode_varint_signed_raw(r)

        if action in @block_actions_with_position do
          {x, r} = decode_varint_signed_raw(r)
          {y, r} = decode_varint_signed_raw(r)
          {z, r} = decode_varint_signed_raw(r)
          {face, r} = decode_varint_signed_raw(r)
          {[{action, {x, y, z}, face} | acc], r}
        else
          {[{action, nil, nil} | acc], r}
        end
      end)

    {Enum.reverse(actions), rest}
  end

  defp bit_set?(value, bit), do: (value >>> bit &&& 1) == 1

  # Skips a LegacySetItemSlot slice: varuint count, each entry a uint8
  # container ID plus a varuint-length byte slice of slots.
  defp skip_legacy_set_item_slots(data) do
    {count, rest} = Codec.decode_varuint(data)

    Enum.reduce(1..count//1, rest, fn _, r ->
      <<_container_id::8, r::binary>> = r
      {len, r} = Codec.decode_varuint(r)
      <<_slots::binary-size(len), r::binary>> = r
      r
    end)
  end

  # Skips one InventoryAction (protocol.InventoryAction marshal order).
  defp skip_inventory_action(data) do
    {_source_type, rest} = Codec.decode_varuint(data)
    <<_present1::8, has_container_id::8, rest::binary>> = rest
    rest = if has_container_id == 0, do: rest, else: skip_bytes(rest, 1)
    <<_present2::8, has_flags::8, rest::binary>> = rest

    rest =
      if has_flags == 0 do
        rest
      else
        {_flags, r} = Codec.decode_varuint(rest)
        r
      end

    {_inventory_slot, rest} = Codec.decode_varuint(rest)
    {_old_block_id, rest} = skip_item_instance(rest)
    {_new_block_id, rest} = skip_item_instance(rest)
    rest
  end

  # Extracts the held item's block runtime ID from a UseItem transaction tail.
  #
  # Two item wire formats are seen in the wild for protocol 1001: gophertunnel
  # reads an always-full li16-id form (ItemInstanceNew), while prismarine's
  # protocol data uses the legacy zigzag-id form where network ID 0 ends the
  # item immediately. Try both; an unparseable item degrades to 0 (empty hand)
  # rather than failing the whole transaction, since breaking doesn't need the
  # item at all and placing has a fallback.
  defp parse_held_block_runtime_id(data) do
    try do
      {id, _rest} = skip_item_instance(data)
      id
    rescue
      _ ->
        try do
          {id, _rest} = skip_item_instance_legacy(data)
          id
        rescue
          _ -> 0
        end
    end
  end

  # ItemInstanceNew wire format (li16 id, all fields always present).
  defp skip_item_instance(data) do
    <<_network_id::16-little-signed, _count::16-little, rest::binary>> = data
    {_metadata, rest} = Codec.decode_varuint(rest)
    <<has_net_id::8, rest::binary>> = rest

    rest =
      if has_net_id == 0 do
        rest
      else
        {_empty, r} = Codec.decode_varuint(rest)
        {_stack_net_id, r} = decode_varint_signed_raw(r)
        r
      end

    {block_runtime_id, rest} = Codec.decode_varuint(rest)
    {extra_len, rest} = Codec.decode_varuint(rest)
    <<_extra::binary-size(extra_len), rest::binary>> = rest
    {block_runtime_id, rest}
  end

  # Legacy item wire format (zigzag32 id; id 0 means empty and ends the item).
  defp skip_item_instance_legacy(data) do
    case decode_varint_signed_raw(data) do
      {0, rest} ->
        {0, rest}

      {_network_id, rest} ->
        <<_count::16-little, rest::binary>> = rest
        {_metadata, rest} = Codec.decode_varuint(rest)
        <<has_stack_id::8, rest::binary>> = rest

        rest =
          if has_stack_id == 0 do
            rest
          else
            {_stack_id, r} = decode_varint_signed_raw(rest)
            r
          end

        {block_runtime_id, rest} = decode_varint_signed_raw(rest)
        {extra_len, rest} = Codec.decode_varuint(rest)
        <<_extra::binary-size(extra_len), rest::binary>> = rest
        # Zigzag-decoded; reinterpret as the unsigned network hash form.
        <<unsigned::32-unsigned>> = <<block_runtime_id::32-signed>>
        {unsigned, rest}
    end
  end

  defp skip_bytes(data, n) do
    <<_skip::binary-size(n), rest::binary>> = data
    rest
  end

  defp decode_varint_signed_raw(data) do
    {zigzag, rest} = Codec.decode_varuint(data)
    value = if (zigzag &&& 1) == 0, do: zigzag >>> 1, else: -(zigzag >>> 1) - 1
    {value, rest}
  end

  # --- JWT parsing (extract player name from chain) ---

  defp extract_player_name(chain_json) do
    case Jason.decode(chain_json) do
      {:ok, %{"chain" => jwts}} ->
        Enum.find_value(jwts, "Player", fn jwt ->
          case decode_jwt_payload(jwt) do
            %{"extraData" => %{"displayName" => name}} -> name
            _ -> nil
          end
        end)

      _ ->
        "Player"
    end
  end

  defp decode_jwt_payload(jwt_string) do
    case String.split(jwt_string, ".") do
      [_, payload_b64 | _] ->
        padded = pad_base64(payload_b64)

        case Base.url_decode64(padded) do
          {:ok, json} -> Jason.decode!(json)
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp pad_base64(str) do
    case rem(byte_size(str), 4) do
      0 -> str
      2 -> str <> "=="
      3 -> str <> "="
      _ -> str
    end
  end
end
