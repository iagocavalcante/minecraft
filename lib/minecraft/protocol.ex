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
    # :infinity — the join-time chunk stream issues thousands of these; the
    # default 5s timeout could spuriously crash the caller under load.
    GenServer.call(pid, {:send_packet, packet}, :infinity)
  end

  def get_conn(pid) do
    GenServer.call(pid, :get_conn, :infinity)
  end

  def set_teleport_id(pid, teleport_id) do
    GenServer.cast(pid, {:set_teleport_id, teleport_id})
  end

  #
  # Server Callbacks
  #

  @impl GenServer
  def init({ref, transport, _protocol_opts}) do
    # Trap exits so that (a) an abnormally dying linked state machine is caught
    # here instead of silently killing us, and (b) `terminate/2` always runs to
    # release the player from the registry.
    Process.flag(:trap_exit, true)
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
    :ok = conn.transport.close(socket)
    {:stop, :normal, conn}
  end

  def handle_info({:tcp_error, _socket, reason}, conn) do
    Logger.warning(fn -> "TCP error for #{conn.client_ip}: #{inspect(reason)}" end)
    {:stop, :normal, conn}
  end

  # Our linked state machine exited (e.g. keepalive timeout). Tear the
  # connection down with it.
  def handle_info({:EXIT, pid, reason}, %Connection{state_machine: pid} = conn) do
    if reason not in [:normal, :shutdown] do
      Logger.warning(fn -> "State machine for #{conn.client_ip} exited: #{inspect(reason)}" end)
    end

    {:stop, :normal, conn}
  end

  def handle_info({:EXIT, _pid, _reason}, conn) do
    {:noreply, conn}
  end

  def handle_info(other, conn) do
    Logger.debug(fn -> "#{__MODULE__} ignoring unexpected message: #{inspect(other)}" end)
    {:noreply, conn}
  end

  @impl true
  def terminate(_reason, conn) do
    if uuid = conn.assigns && conn.assigns[:uuid] do
      Minecraft.Users.leave(uuid)
    end

    # Stop the linked state machine explicitly: a `:normal` exit signal would
    # otherwise be ignored by the (non-trapping) state machine, leaking it.
    if is_pid(conn.state_machine) and Process.alive?(conn.state_machine) do
      :gen_statem.stop(conn.state_machine)
    end

    :ok
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
  defp handle_conn(%Connection{error: error} = conn) when not is_nil(error) do
    Logger.error(fn -> "#{__MODULE__} closing connection: #{inspect(error)}" end)
    conn = Connection.close(conn)
    {:stop, :normal, conn}
  end

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

      {:incomplete, conn} ->
        # Not enough bytes buffered for a full packet; wait for more.
        conn = Connection.continue(conn)
        {:noreply, conn}

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
