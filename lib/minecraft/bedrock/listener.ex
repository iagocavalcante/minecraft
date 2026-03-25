defmodule Minecraft.Bedrock.Listener do
  @moduledoc """
  UDP listener for Bedrock Edition on port 19132.
  Routes RakNet offline packets and forwards connection data to sessions.
  """
  use GenServer
  import Bitwise
  require Logger
  alias Minecraft.Bedrock.RakNet

  @default_port 19132

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def send_to(address, port, data) do
    GenServer.cast(__MODULE__, {:send, address, port, data})
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    bind_ip = resolve_bind_address()
    {:ok, socket} = :gen_udp.open(port, [:binary, active: true, reuseaddr: true, ip: bind_ip])
    server_guid = :rand.uniform(1 <<< 63)
    Logger.info("Bedrock listener started on UDP #{:inet.ntoa(bind_ip)}:#{port}")
    {:ok, %{socket: socket, port: port, server_guid: server_guid, sessions: %{}}}
  end

  # Fly.io requires UDP to bind to fly-global-services address
  defp resolve_bind_address do
    case :inet.getaddr(~c"fly-global-services", :inet) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end
  end

  @impl true
  def handle_info({:udp, _socket, address, port, data}, state) do
    state = handle_packet(address, port, data, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    sessions =
      state.sessions
      |> Enum.reject(fn {_key, session_pid} -> session_pid == pid end)
      |> Map.new()

    {:noreply, %{state | sessions: sessions}}
  end

  @impl true
  def handle_cast({:send, address, port, data}, state) do
    :gen_udp.send(state.socket, address, port, data)
    {:noreply, state}
  end

  # --- Packet Routing ---

  defp handle_packet(address, port, data, state) do
    case RakNet.decode(data) do
      {:unconnected_ping, %{timestamp: ts}} ->
        motd = build_motd(state.server_guid)
        pong = RakNet.encode_unconnected_pong(ts, state.server_guid, motd)
        :gen_udp.send(state.socket, address, port, pong)
        state

      {:open_connection_request_1, %{protocol_version: 11, mtu_size: mtu}} ->
        reply = RakNet.encode_open_connection_reply_1(state.server_guid, mtu)
        :gen_udp.send(state.socket, address, port, reply)
        state

      {:open_connection_request_1, _} ->
        reply = RakNet.encode_incompatible_protocol(state.server_guid)
        :gen_udp.send(state.socket, address, port, reply)
        state

      {:open_connection_request_2, %{mtu_size: mtu, client_guid: client_guid}} ->
        reply = RakNet.encode_open_connection_reply_2(state.server_guid, address, port, mtu)
        :gen_udp.send(state.socket, address, port, reply)

        client_key = {address, port}

        case Minecraft.Bedrock.SessionSupervisor.start_session(
               client_key,
               state.server_guid,
               mtu,
               client_guid
             ) do
          {:ok, pid} ->
            Process.monitor(pid)
            sessions = Map.put(state.sessions, client_key, pid)
            %{state | sessions: sessions}

          {:error, reason} ->
            Logger.error("Failed to start Bedrock session: #{inspect(reason)}")
            state
        end

      _ ->
        client_key = {address, port}

        case Map.get(state.sessions, client_key) do
          nil ->
            state

          pid ->
            send(pid, {:raknet_data, data})
            state
        end
    end
  end

  defp build_motd(server_guid) do
    "MCPE;Elixir Minecraft;944;1.26.10;0;20;#{server_guid};Bedrock Level;Survival;1;19132;19133"
  end
end
