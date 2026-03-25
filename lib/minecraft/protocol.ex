defmodule Minecraft.Protocol do
  @moduledoc """
  A [`:ranch_protocol`](https://ninenines.eu/docs/en/ranch/1.5/guide/protocols/) implementation
  that forwards requests to `Minecraft.Protocol.Handler`.
  """
  use GenServer
  require Logger
  alias Minecraft.Connection
  alias Minecraft.Packet.Server
  alias Minecraft.Protocol.Handler

  @behaviour :ranch_protocol

  @impl :ranch_protocol
  def start_link(ref, transport, protocol_opts) do
    pid = :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, protocol_opts}])
    {:ok, pid}
  end

  @doc """
  Sends a packet to the connected client.
  """
  @spec send_packet(pid, struct) :: :ok | {:error, term}
  def send_packet(pid, packet) do
    GenServer.call(pid, {:send_packet, packet})
  end

  def get_conn(pid) do
    GenServer.call(pid, :get_conn)
  end

  def set_teleport_id(pid, teleport_id) do
    GenServer.cast(pid, {:set_teleport_id, teleport_id})
  end

  #
  # Server Callbacks
  #

  @impl GenServer
  def init({ref, transport, _protocol_opts}) do
    {:ok, socket} = :ranch.handshake(ref)
    conn = Connection.init(self(), socket, transport)
    :gen_server.enter_loop(__MODULE__, [], conn)
  end

  @impl true
  def handle_info({:tcp, socket, data}, conn) do
    conn
    |> Connection.put_socket(socket)
    |> Connection.put_data(data)
    |> handle_conn()
  end

  def handle_info({:tcp_closed, socket}, conn) do
    Logger.info(fn -> "Client #{conn.client_ip} disconnected." end)

    if uuid = conn.assigns[:uuid] do
      Minecraft.Users.leave(uuid)
    end

    :ok = conn.transport.close(socket)
    {:stop, :normal, conn}
  end

  @impl true
  def handle_call({:send_packet, packet}, _from, conn) do
    conn = Connection.send_packet(conn, packet)
    {:reply, :ok, conn}
  end

  def handle_call(:get_conn, _from, conn) do
    {:reply, conn, conn}
  end

  @impl true
  def handle_cast({:set_teleport_id, teleport_id}, conn) do
    {:noreply, Connection.assign(conn, :teleport_id, teleport_id)}
  end

  #
  # Helpers
  #
  defp handle_conn(%Connection{join: true, state_machine: nil} = conn) do
    {:ok, state_machine} = Minecraft.StateMachine.start_link(self())
    handle_conn(%Connection{conn | state_machine: state_machine})
  end

  defp handle_conn(%Connection{data: ""} = conn) do
    conn = Connection.continue(conn)
    {:noreply, conn}
  end

  defp handle_conn(%Connection{} = conn) do
    case Connection.read_packet(conn) do
      {:ok, packet, conn} ->
        handle_packet(packet, conn)

      {:error, conn} ->
        conn = Connection.close(conn)
        {:stop, :normal, conn}
    end
  end

  defp handle_packet(packet, conn) do
    case Handler.handle(packet, conn) do
      {:ok, :noreply, conn} ->
        handle_conn(conn)

      {:ok, response, conn} ->
        conn
        |> Connection.send_packet(response)
        |> handle_conn()

      {:error, reason, conn} = err ->
        Logger.error(fn -> "#{__MODULE__} error: #{inspect(err)}" end)

        conn =
          if conn.current_state == :login do
            reason_json = Jason.encode!(%{text: "Login failed: #{reason}"})
            Connection.send_packet(conn, %Server.Login.Disconnect{reason: reason_json})
          else
            conn
          end

        Connection.close(conn)
        {:stop, :normal, conn}
    end
  end
end
