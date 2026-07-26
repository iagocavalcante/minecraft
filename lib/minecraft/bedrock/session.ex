defmodule Minecraft.Bedrock.Session do
  @moduledoc """
  Per-client GenServer managing a RakNet session + Bedrock protocol state.

  State machine:
    :connecting → RakNet connected handshake
    :pre_login  → recv RequestNetworkSettings → send NetworkSettings
    :logging_in → recv Login → send PlayStatus(login_success)
    :resource_packs → send/recv resource pack exchange
    :starting   → send StartGame + PlayStatus(player_spawn)
    :spawning   → recv RequestChunkRadius → send chunks → recv SetLocalPlayerAsInitialised
    :playing    → gameplay
  """
  use GenServer, restart: :temporary
  require Logger
  alias Minecraft.Bedrock.RakNet
  alias Minecraft.Bedrock.RakNet.{Frame, FrameSet}
  alias Minecraft.Bedrock.{Codec, Packet}

  defstruct [
    :client_key,
    :server_guid,
    :mtu,
    :client_guid,
    :player_name,
    send_seq: 0,
    reliable_index: 0,
    order_index: 0,
    split_id: 0,
    splits: %{},
    bedrock_state: :connecting,
    compression_enabled: false,
    position: nil,
    rotation: nil
  ]

  # Java 1.12 global block types (id <<< 4 ||| meta).
  @java_air 0
  @java_stone 16

  def start_link({client_key, server_guid, mtu, client_guid}) do
    GenServer.start_link(__MODULE__, {client_key, server_guid, mtu, client_guid})
  end

  @impl true
  def init({client_key, server_guid, mtu, client_guid}) do
    state = %__MODULE__{
      client_key: client_key,
      server_guid: server_guid,
      mtu: mtu,
      client_guid: client_guid
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:raknet_data, data}, state) do
    state = handle_raknet(data, state)
    {:noreply, state}
  end

  def handle_info(:client_disconnected, state) do
    {:stop, :normal, state}
  end

  # =====================
  # RakNet Layer
  # =====================

  defp handle_raknet(data, state) do
    case FrameSet.decode(data) do
      {:frame_set, seq, frames} ->
        ack = FrameSet.encode_ack([seq])
        send_raw(state, ack)
        Enum.reduce(frames, state, &handle_frame/2)

      {:ack, sequences} ->
        Logger.debug("Bedrock: got ACK for seq #{inspect(sequences)}")
        state

      {:nak, sequences} ->
        Logger.debug("Bedrock: got NAK for seq #{inspect(sequences)}")
        state

      _ ->
        Logger.debug(
          "Bedrock: unknown RakNet data, first byte: #{inspect(:binary.part(data, 0, min(byte_size(data), 5)))}"
        )

        state
    end
  end

  defp handle_frame(%Frame{split: nil} = frame, state) do
    Logger.debug(
      "Bedrock: frame body (#{byte_size(frame.body)}b) first: #{inspect(:binary.part(frame.body, 0, min(byte_size(frame.body), 5)))}"
    )

    handle_payload(frame.body, state)
  end

  defp handle_frame(%Frame{split: %{id: id, count: count, index: index} = split} = frame, state) do
    Logger.debug(
      "Bedrock: split frame #{index + 1}/#{count} (id=#{id}, #{byte_size(frame.body)}b)"
    )

    parts = Map.get(state.splits, id, %{count: count, parts: %{}})
    parts = %{parts | parts: Map.put(parts.parts, index, frame.body)}

    if map_size(parts.parts) == count do
      body =
        Enum.map(0..(count - 1), fn i -> Map.fetch!(parts.parts, i) end)
        |> IO.iodata_to_binary()

      Logger.debug(
        "Bedrock: reassembled split (#{byte_size(body)}b) first: #{inspect(:binary.part(body, 0, min(byte_size(body), 10)))} compression=#{state.compression_enabled}"
      )

      state = %{state | splits: Map.delete(state.splits, id)}
      handle_payload(body, state)
    else
      %{state | splits: Map.put(state.splits, id, parts)}
    end
  end

  # =====================
  # RakNet Connected Handshake
  # =====================

  defp handle_payload(<<0x09, _client_guid::64, timestamp::64-signed, _::binary>>, state) do
    Logger.info("Bedrock: ConnectionRequest from #{inspect(state.client_key)}")
    reply = encode_connection_request_accepted(state, timestamp)
    state = send_reliable(state, reply)
    state
  end

  defp handle_payload(<<0x13, _rest::binary>>, state) do
    Logger.info("Bedrock: NewIncomingConnection — RakNet handshake complete")
    %{state | bedrock_state: :pre_login}
  end

  defp handle_payload(<<0x00, timestamp::64-signed>>, state) do
    now = System.system_time(:millisecond)
    pong = <<0x03, timestamp::64-signed, now::64-signed>>
    send_reliable(state, pong)
  end

  # RakNet DisconnectionNotification — the client is leaving; stop the session.
  defp handle_payload(<<0x15, _::binary>>, state) do
    Logger.info("Bedrock: client #{inspect(state.client_key)} disconnected (RakNet 0x15)")
    send(self(), :client_disconnected)
    state
  end

  # =====================
  # Bedrock Game Layer (0xFE batch)
  # =====================

  defp handle_payload(<<0xFE, _::binary>> = data, state) do
    case Codec.decode_batch(data, state.compression_enabled) do
      {:ok, packets} ->
        Enum.reduce(packets, state, fn pkt, st ->
          # A malformed or not-yet-supported packet must not take down the
          # whole session; log it and keep going.
          try do
            handle_game_packet(Packet.decode(pkt), st)
          rescue
            error ->
              Logger.warning(
                "Bedrock: error handling game packet " <>
                  "#{inspect(:binary.part(pkt, 0, min(byte_size(pkt), 8)))}: " <>
                  Exception.message(error)
              )

              st
          end
        end)

      {:error, reason} ->
        Logger.warning("Bedrock: failed to decode batch: #{inspect(reason)}")
        state
    end
  end

  defp handle_game_packet({:request_network_settings, %{protocol_version: ver}}, state) do
    Logger.info("Bedrock: Client protocol version: #{ver}")
    handle_request_network_settings(state)
  end

  defp handle_game_packet({:login, %{player_name: name}}, state) do
    handle_login(name, state)
  end

  defp handle_game_packet({:client_cache_status, %{supported: supported}}, state) do
    # Informational only — we never use the blob cache.
    Logger.debug("Bedrock: ClientCacheStatus supported=#{supported}")
    state
  end

  defp handle_game_packet({:resource_pack_client_response, %{status: :have_all_packs}}, state) do
    handle_resource_pack_response_have_all(state)
  end

  defp handle_game_packet({:resource_pack_client_response, %{status: :completed}}, state) do
    handle_resource_pack_completed(state)
  end

  defp handle_game_packet({:request_chunk_radius, %{radius: radius}}, state) do
    handle_request_chunk_radius(radius, state)
  end

  defp handle_game_packet({:set_local_player_as_initialised, _}, state) do
    handle_player_initialised(state)
  end

  # PlayerBlockAction: PredictDestroyBlock — the client (in creative, or with
  # server-auth breaking) predicts the block is gone; the server applies it.
  @action_predict_destroy_block 26

  defp handle_game_packet({:player_auth_input, %{position: position} = input}, state) do
    # ~20/s — track the latest position/rotation, then apply any block
    # actions and item interactions this tick carried.
    state = %{state | position: position, rotation: {input.pitch, input.yaw, input.head_yaw}}

    state =
      Enum.reduce(Map.get(input, :block_actions, []), state, fn
        {@action_predict_destroy_block, {x, y, z}, _face}, st ->
          handle_break_block({x, y, z}, st)

        {_action, _pos, _face}, st ->
          st
      end)

    case Map.get(input, :item_interaction) do
      %{action_type: 0} = interaction ->
        handle_place_block(
          interaction.block_position,
          interaction.face,
          interaction.held_block_runtime_id,
          state
        )

      _ ->
        state
    end
  end

  defp handle_game_packet(
         {:inventory_transaction, %{type: :use_item, action: :break_block} = tx},
         state
       ) do
    handle_break_block(tx.block_position, state)
  end

  defp handle_game_packet(
         {:inventory_transaction, %{type: :use_item, action: :click_block} = tx},
         state
       ) do
    handle_place_block(tx.block_position, tx.face, tx.held_block_runtime_id, state)
  end

  defp handle_game_packet(other, state) do
    Logger.debug("Bedrock: unhandled game packet: #{inspect(other)}")
    state
  end

  # Catch-all: try to decode as a raw game packet or log for debugging
  defp handle_payload(data, state) when byte_size(data) > 0 do
    Logger.debug(
      "Bedrock: raw payload in #{state.bedrock_state}, first bytes: #{inspect(:binary.part(data, 0, min(byte_size(data), 20)))}"
    )

    # Try decoding as a game packet directly
    case Packet.decode(data) do
      {:request_network_settings, %{protocol_version: _ver}} ->
        handle_request_network_settings(state)

      {:login, %{player_name: name}} ->
        handle_login(name, state)

      other ->
        Logger.debug("Bedrock: unhandled packet: #{inspect(other)}")
        state
    end
  end

  defp handle_payload(_data, state), do: state

  # =====================
  # Bedrock State Machine Handlers
  # =====================

  defp handle_request_network_settings(state) do
    Logger.info("Bedrock: RequestNetworkSettings")
    # NetworkSettings sent in uncompressed 0xFE batch (compression not yet active)
    state = send_game_packet(state, Packet.encode_network_settings(256), false)
    %{state | bedrock_state: :logging_in, compression_enabled: true}
  end

  defp handle_login(player_name, state) do
    Logger.info("Bedrock: Login from '#{player_name}'")

    state = %{state | player_name: player_name}
    # Vanilla order: PlayStatus(login_success) then ResourcePacksInfo, without
    # waiting for anything from the client (ClientCacheStatus arrival varies by
    # client and must not gate the flow). Separate batches on purpose.
    state = send_game_packet(state, Packet.encode_play_status(:login_success))
    state = send_game_packet(state, Packet.encode_resource_packs_info())
    %{state | bedrock_state: :resource_packs}
  end

  defp handle_resource_pack_response_have_all(state) do
    Logger.info("Bedrock: Client has all packs — sending ResourcePackStack")
    state = send_game_packet(state, Packet.encode_resource_pack_stack())
    %{state | bedrock_state: :resource_packs}
  end

  defp handle_resource_pack_completed(state) do
    Logger.info("Bedrock: Resource packs completed — sending StartGame")

    # Spawn just above the generated terrain surface at world origin so the
    # player lands on the ground instead of inside it (or in the void).
    surface = Minecraft.Bedrock.Chunk.surface_y(Minecraft.World.get_chunk(0, 0), 0, 0)

    start_game =
      Packet.encode_start_game(
        entity_id: 1,
        runtime_id: 1,
        game_mode: 1,
        position: {0.5, surface + 3.0, 0.5},
        spawn: {0, surface + 1, 0},
        world_name: "Elixir Minecraft"
      )

    state = send_game_packet(state, start_game)
    # gophertunnel sends ItemRegistry immediately after StartGame.
    state = send_game_packet(state, Packet.encode_item_registry())
    # Don't send PlayStatus(PlayerSpawn) yet — wait for RequestChunkRadius + chunks first
    %{state | bedrock_state: :spawning}
  end

  defp handle_request_chunk_radius(radius, state) do
    Logger.info("Bedrock: RequestChunkRadius #{radius}")
    actual_radius = radius |> min(8) |> max(2)

    state = send_game_packet(state, Packet.encode_chunk_radius_updated(actual_radius))

    spawn_chunk = Minecraft.World.get_chunk(0, 0)
    surface = Minecraft.Bedrock.Chunk.surface_y(spawn_chunk, 0, 0)

    state =
      Enum.reduce(-actual_radius..actual_radius, state, fn x, st ->
        Enum.reduce(-actual_radius..actual_radius, st, fn z, st2 ->
          chunk = Minecraft.World.get_chunk(x, z)
          {sub_chunks, chunk_data} = Minecraft.Bedrock.Chunk.encode(chunk)
          send_game_packet(st2, Packet.encode_level_chunk(x, z, sub_chunks, chunk_data))
        end)
      end)

    state =
      send_game_packet(
        state,
        Packet.encode_network_chunk_publisher_update(0, surface + 1, 0, actual_radius * 16)
      )

    # Send PlayStatus(PlayerSpawn) AFTER chunks (matches gophertunnel order)
    send_game_packet(state, Packet.encode_play_status(:player_spawn))
  end

  defp handle_player_initialised(state) do
    Logger.info("Bedrock: Player '#{state.player_name}' fully spawned!")
    %{state | bedrock_state: :playing}
  end

  defp handle_break_block({x, y, z}, state) do
    case Minecraft.World.set_block(x, y, z, @java_air) do
      :ok ->
        Logger.info("Bedrock: '#{state.player_name}' broke block at #{x},#{y},#{z}")
        air = Minecraft.Bedrock.Chunk.network_hash(@java_air)
        send_game_packet(state, Packet.encode_update_block(x, y, z, air))

      :error ->
        Logger.warning("Bedrock: rejected break at #{x},#{y},#{z} (out of world range)")
        state
    end
  end

  defp handle_place_block({x, y, z}, face, held_block_runtime_id, state) do
    {dx, dy, dz} = face_offset(face)
    {tx, ty, tz} = {x + dx, y + dy, z + dz}

    # The held item's block runtime ID (a network block hash) determines what
    # gets placed. Until the creative item pipeline exists (ItemRegistry +
    # CreativeContent are empty), an empty hand or unknown block places stone.
    java_type =
      case Minecraft.Bedrock.Chunk.java_type_for_network_hash(held_block_runtime_id) do
        {:ok, type} when type != @java_air -> type
        _ -> @java_stone
      end

    case Minecraft.World.set_block(tx, ty, tz, java_type) do
      :ok ->
        Logger.info("Bedrock: '#{state.player_name}' placed #{java_type} at #{tx},#{ty},#{tz}")
        hash = Minecraft.Bedrock.Chunk.network_hash(java_type)
        send_game_packet(state, Packet.encode_update_block(tx, ty, tz, hash))

      :error ->
        Logger.warning("Bedrock: rejected place at #{tx},#{ty},#{tz} (out of world range)")
        state
    end
  end

  # Block face → adjacent-position offset (down, up, north, south, west, east).
  defp face_offset(0), do: {0, -1, 0}
  defp face_offset(1), do: {0, 1, 0}
  defp face_offset(2), do: {0, 0, -1}
  defp face_offset(3), do: {0, 0, 1}
  defp face_offset(4), do: {-1, 0, 0}
  defp face_offset(5), do: {1, 0, 0}
  defp face_offset(_other), do: {0, 1, 0}

  # =====================
  # Send Helpers
  # =====================

  defp send_raw(state, data) do
    {address, port} = state.client_key
    Minecraft.Bedrock.Listener.send_to(address, port, data)
    state
  end

  defp send_game_packet(state, packet_data, compress? \\ true) do
    batch =
      if compress? and state.compression_enabled do
        Codec.encode_batch([packet_data])
      else
        Codec.encode_batch_uncompressed([packet_data])
      end

    send_reliable_fragmented(state, batch)
  end

  defp send_reliable(state, payload) do
    frame = %Frame{
      reliability: 3,
      reliable_index: state.reliable_index,
      order_index: state.order_index,
      order_channel: 0,
      body: payload
    }

    frame_set = FrameSet.encode(state.send_seq, [frame])
    send_raw(state, frame_set)

    %{
      state
      | send_seq: state.send_seq + 1,
        reliable_index: state.reliable_index + 1,
        order_index: state.order_index + 1
    }
  end

  defp send_reliable_fragmented(state, payload) do
    max_body = state.mtu - 60

    if byte_size(payload) <= max_body do
      send_reliable(state, payload)
    else
      chunks = chunk_binary(payload, max_body)
      count = length(chunks)
      split_id = state.split_id

      {state, _} =
        Enum.reduce(chunks, {state, 0}, fn chunk, {st, index} ->
          frame = %Frame{
            reliability: 3,
            reliable_index: st.reliable_index,
            order_index: st.order_index,
            order_channel: 0,
            split: %{count: count, id: split_id, index: index},
            body: chunk
          }

          frame_set = FrameSet.encode(st.send_seq, [frame])
          send_raw(st, frame_set)

          st = %{
            st
            | send_seq: st.send_seq + 1,
              reliable_index: st.reliable_index + 1
          }

          {st, index + 1}
        end)

      %{state | split_id: split_id + 1, order_index: state.order_index + 1}
    end
  end

  defp chunk_binary(<<>>, _size), do: []

  defp chunk_binary(data, size) when byte_size(data) <= size do
    [data]
  end

  defp chunk_binary(data, size) do
    <<chunk::binary-size(size), rest::binary>> = data
    [chunk | chunk_binary(rest, size)]
  end

  # =====================
  # RakNet Packet Helpers
  # =====================

  defp encode_connection_request_accepted(state, client_timestamp) do
    {address, port} = state.client_key
    client_addr = RakNet.encode_address(address, port)
    system_index = <<0::16>>
    internal_addrs = :binary.copy(RakNet.encode_address({0, 0, 0, 0}, 0), 10)
    now = System.system_time(:millisecond)

    <<0x10, client_addr::binary, system_index::binary, internal_addrs::binary,
      client_timestamp::64-signed, now::64-signed>>
  end
end
