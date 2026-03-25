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
  @request_chunk_radius 0x45
  @chunk_radius_updated 0x46
  @level_chunk 0x3A
  @set_local_player_as_initialised 0x71
  @network_chunk_publisher_update 0x79
  @network_settings 0x8F
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
      encode_varint_signed(x)::binary,
      encode_varint_unsigned(y)::binary,
      encode_varint_signed(z)::binary,
      encode_varint_unsigned(radius)::binary,
      0::32-little
    >>

    wrap(@network_chunk_publisher_update, body)
  end

  @doc "LevelChunk — send chunk data to client"
  def encode_level_chunk(x, z, sub_chunk_count, chunk_data, biome_data \\ <<>>) do
    body = <<
      encode_varint_signed(x)::binary,
      encode_varint_signed(z)::binary,
      encode_varint_unsigned(sub_chunk_count)::binary,
      0::8,
      0::8,
      encode_varint_unsigned(byte_size(chunk_data) + byte_size(biome_data))::binary,
      chunk_data::binary,
      biome_data::binary
    >>

    wrap(@level_chunk, body)
  end

  @doc """
  StartGame — matches gophertunnel Marshal order for protocol 924.
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
        # WorldSpawn.X (UBlockPos)
        encode_varint_signed(spx),
        # WorldSpawn.Y
        encode_varint_unsigned(spy),
        # WorldSpawn.Z
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
        # Blocks (Slice, empty)
        encode_varint_unsigned(0),
        # MultiPlayerCorrelationID
        encode_string(""),
        # ServerAuthoritativeInventory
        <<0::8>>,
        # GameVersion
        encode_string("1.26.0"),
        # PropertyData — empty NBT compound (NetworkLittleEndian)
        # TAG_Compound(0x0A) + varint name_len(0) + TAG_End(0x00)
        <<0x0A, 0x00, 0x00>>,
        # ServerBlockStateChecksum (uint64)
        <<0::64-little>>,
        # WorldTemplateID (UUID, 16 bytes)
        <<0::128>>,
        # ClientSideGeneration
        <<0::8>>,
        # UseBlockNetworkIDHashes
        <<1::8>>,
        # ServerAuthoritativeSound
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

  # ClientCacheStatus (0x81 = 129) — client tells us if it supports blob cache
  defp decode_by_id(0x81, <<supported::8, _rest::binary>>) do
    {:client_cache_status, %{supported: supported != 0}}
  end

  defp decode_by_id(id, _rest) do
    {:unknown_bedrock_packet, id}
  end

  # =====================
  # PRIVATE HELPERS
  # =====================

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
