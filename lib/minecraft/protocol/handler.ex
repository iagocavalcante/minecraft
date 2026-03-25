defmodule Minecraft.Protocol.Handler do
  @moduledoc """
  Server-side handler for responding to client packets.
  """
  alias Minecraft.Connection
  alias Minecraft.Crypto
  alias Minecraft.Packet.Client
  alias Minecraft.Packet.Server

  @doc """
  Handles a packet from a client, and returns either a response packet, or `{:ok, :noreply}`.
  """
  @spec handle(packet :: Minecraft.Packet.packet_types(), Connection.t()) ::
          {:ok, :noreply | struct, Connection.t()}
          | {:error, :unsupported_protocol, Connection.t()}
  def handle(%Client.Handshake{protocol_version: 340} = packet, conn) do
    conn =
      conn
      |> Connection.put_state(packet.next_state)
      |> Connection.put_protocol(340)
      |> Connection.assign(:server_addr, packet.server_addr)

    {:ok, :noreply, conn}
  end

  def handle(%Client.Handshake{protocol_version: _}, conn) do
    {:error, :unsupported_protocol, conn}
  end

  def handle(%Client.Status.Request{}, conn) do
    json =
      Jason.encode!(%{
        version: %{name: "1.12.2", protocol: 340},
        players: %{max: 20, online: 0, sample: []},
        description: %{text: "Elixir Minecraft"}
      })

    {:ok, %Server.Status.Response{json: json}, conn}
  end

  def handle(%Client.Status.Ping{payload: payload}, conn) do
    {:ok, %Server.Status.Pong{payload: payload}, conn}
  end

  def handle(%Client.Login.LoginStart{username: username}, conn) do
    verify_token = :crypto.strong_rand_bytes(4)

    conn =
      conn
      |> Connection.assign(:username, username)
      |> Connection.assign(:verify_token, verify_token)

    response = %Server.Login.EncryptionRequest{
      server_id: "",
      public_key: Crypto.get_public_key(),
      verify_token: verify_token
    }

    {:ok, response, conn}
  end

  def handle(%Client.Login.EncryptionResponse{} = packet, conn) do
    verify_token = Crypto.decrypt(packet.verify_token)

    case conn.assigns[:verify_token] do
      ^verify_token ->
        shared_secret = Crypto.decrypt(packet.shared_secret)

        conn =
          conn
          |> Connection.encrypt(shared_secret)
          |> Connection.verify_login()
          |> Connection.put_state(:play)
          |> Connection.join()

        response = %Server.Login.LoginSuccess{
          uuid: conn.assigns[:uuid],
          username: conn.assigns[:username]
        }

        {:ok, response, conn}

      _ ->
        {:error, :bad_verify_token, conn}
    end
  end

  def handle(%Client.Play.ClientSettings{} = packet, conn) do
    conn =
      conn
      |> Connection.put_setting(:locale, packet.locale)
      |> Connection.put_setting(:view_distance, packet.view_distance)
      |> Connection.put_setting(:chat_mode, packet.chat_mode)
      |> Connection.put_setting(:chat_colors, packet.chat_colors)
      |> Connection.put_setting(:displayed_skin_parts, packet.displayed_skin_parts)
      |> Connection.put_setting(:main_hand, packet.main_hand)

    {:ok, :noreply, conn}
  end

  def handle(%Client.Play.PluginMessage{}, conn) do
    {:ok, :noreply, conn}
  end

  def handle(%Client.Play.TeleportConfirm{teleport_id: id}, conn) do
    case conn.assigns[:teleport_id] do
      ^id -> {:ok, :noreply, conn}
      _ -> {:error, :invalid_teleport_id, conn}
    end
  end

  def handle(%Client.Play.ChatMessage{message: message}, conn) do
    username = conn.assigns[:username] || "Unknown"
    json = Jason.encode!(%{text: "<#{username}> #{message}"})
    {:ok, %Server.Play.ChatMessage{json_data: json, position: 0}, conn}
  end

  def handle(%Client.Play.Player{}, conn) do
    {:ok, :noreply, conn}
  end

  def handle(%Client.Play.PlayerPosition{} = packet, conn) do
    position = {packet.x, packet.y, packet.z}
    :ok = Minecraft.Users.update_position(conn.assigns[:uuid], position)
    {:ok, :noreply, conn}
  end

  def handle(%Client.Play.PlayerPositionAndLook{} = packet, conn) do
    position = {packet.x, packet.y, packet.z}
    look = {packet.yaw, packet.pitch}
    :ok = Minecraft.Users.update_position(conn.assigns[:uuid], position)
    :ok = Minecraft.Users.update_look(conn.assigns[:uuid], look)
    {:ok, :noreply, conn}
  end

  def handle(%Client.Play.PlayerLook{} = packet, conn) do
    look = {packet.yaw, packet.pitch}
    :ok = Minecraft.Users.update_look(conn.assigns[:uuid], look)
    {:ok, :noreply, conn}
  end

  def handle(%Client.Play.ClientStatus{}, conn) do
    # TODO: Send Statistics when packet.action == :request_stats
    {:ok, :noreply, conn}
  end

  def handle(%Client.Play.KeepAlive{keep_alive_id: id}, conn) do
    if conn.state_machine do
      send(conn.state_machine, {:keepalive_ack, id})
    end

    {:ok, :noreply, conn}
  end

  def handle(nil, conn) do
    {:ok, :noreply, conn}
  end

  def handle({:error, _}, conn) do
    {:ok, :noreply, conn}
  end
end
