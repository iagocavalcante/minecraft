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
    compression_enabled: false
  ]

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

  # =====================
  # Bedrock Game Layer (0xFE batch)
  # =====================

  defp handle_payload(<<0xFE, _::binary>> = data, state) do
    case Codec.decode_batch(data, state.compression_enabled) do
      {:ok, packets} ->
        Enum.reduce(packets, state, fn pkt, st ->
          case Packet.decode(pkt) do
            {:request_network_settings, %{protocol_version: _ver}} ->
              handle_request_network_settings(st)

            {:login, %{player_name: name}} ->
              handle_login(name, st)

            {:client_cache_status, _} ->
              Logger.debug("Bedrock: ClientCacheStatus — sending ResourcePacksInfo")
              send_game_packet(st, Packet.encode_resource_packs_info())

            {:resource_pack_client_response, %{status: :have_all_packs}} ->
              handle_resource_pack_response_have_all(st)

            {:resource_pack_client_response, %{status: :completed}} ->
              handle_resource_pack_completed(st)

            {:request_chunk_radius, %{radius: radius}} ->
              handle_request_chunk_radius(radius, st)

            {:set_local_player_as_initialised, _} ->
              handle_player_initialised(st)

            other ->
              Logger.debug("Bedrock: unhandled game packet: #{inspect(other)}")
              st
          end
        end)

      {:error, reason} ->
        Logger.warning("Bedrock: failed to decode batch: #{inspect(reason)}")
        state
    end
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
    # Send PlayStatus first, then ResourcePacksInfo
    # They must be separate batches for the client to process correctly
    state = send_game_packet(state, Packet.encode_play_status(:login_success))
    %{state | bedrock_state: :awaiting_cache_status}
  end

  defp handle_resource_pack_response_have_all(state) do
    Logger.info("Bedrock: Client has all packs — sending ResourcePackStack")
    state = send_game_packet(state, Packet.encode_resource_pack_stack())
    %{state | bedrock_state: :resource_packs}
  end

  defp handle_resource_pack_completed(state) do
    Logger.info("Bedrock: Resource packs completed — sending StartGame")

    start_game =
      Packet.encode_start_game(
        entity_id: 1,
        runtime_id: 1,
        game_mode: 1,
        position: {0.0, 64.0, 0.0},
        spawn: {0, 64, 0},
        world_name: "Elixir Minecraft"
      )

    state = send_game_packet(state, start_game)
    state = send_game_packet(state, Packet.encode_play_status(:player_spawn))

    %{state | bedrock_state: :spawning}
  end

  defp handle_request_chunk_radius(radius, state) do
    Logger.info("Bedrock: RequestChunkRadius #{radius}")
    actual_radius = min(radius, 4)

    state = send_game_packet(state, Packet.encode_chunk_radius_updated(actual_radius))

    state =
      Enum.reduce(-actual_radius..actual_radius, state, fn x, st ->
        Enum.reduce(-actual_radius..actual_radius, st, fn z, st2 ->
          chunk_data = Minecraft.Bedrock.Chunk.flat_chunk()
          send_game_packet(st2, Packet.encode_level_chunk(x, z, 4, chunk_data))
        end)
      end)

    send_game_packet(
      state,
      Packet.encode_network_chunk_publisher_update(0, 64, 0, actual_radius * 16)
    )
  end

  defp handle_player_initialised(state) do
    Logger.info("Bedrock: Player '#{state.player_name}' fully spawned!")
    %{state | bedrock_state: :playing}
  end

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
