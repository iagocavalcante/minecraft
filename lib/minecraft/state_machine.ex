defmodule Minecraft.StateMachine do
  @moduledoc """
  Implements core Minecraft logic.

  Minecraft can be thought of as a finite state machine, where transitions occur based on
  client interactions and server intervention. This module implements the `:gen_statem`
  behaviour.
  """
  alias Minecraft.Packet.Server
  alias Minecraft.Protocol
  @behaviour :gen_statem

  @keepalive_timeout_ms 30_000

  @doc """
  Starts the state machine.
  """
  @spec start_link(protocol :: pid) :: :gen_statem.start_ret()
  def start_link(protocol) do
    :gen_statem.start_link(__MODULE__, protocol, [])
  end

  @impl true
  def callback_mode() do
    [:state_functions, :state_enter]
  end

  @impl true
  def init(protocol) do
    data = %{protocol: protocol, last_keepalive_ack: System.system_time(:millisecond)}
    {:ok, :join, data, [{:next_event, :internal, nil}]}
  end

  @impl true
  def terminate(_reason, _state, _data) do
    :ignored
  end

  @doc """
  State entered when a client logs in and begins joining the server.
  """
  def join(:internal, _, data) do
    protocol = data.protocol
    conn = Protocol.get_conn(protocol)
    :ok = Minecraft.Users.join(conn.assigns[:uuid], conn.assigns[:username])

    :ok =
      Protocol.send_packet(protocol, %Server.Play.JoinGame{entity_id: 123, game_mode: :creative})

    :ok = Protocol.send_packet(protocol, %Server.Play.SpawnPosition{position: {0, 200, 0}})

    :ok =
      Protocol.send_packet(protocol, %Server.Play.TimeUpdate{world_age: 0, time_of_day: 6000})

    :ok =
      Protocol.send_packet(protocol, %Server.Play.PlayerAbilities{
        creative_mode: true,
        allow_flying: true,
        flying_speed: 0.1
      })

    teleport_id = :rand.uniform(127)

    :ok =
      Protocol.send_packet(protocol, %Server.Play.PlayerPositionAndLook{
        teleport_id: teleport_id
      })

    Protocol.set_teleport_id(protocol, teleport_id)

    :ok =
      Protocol.send_packet(protocol, %Server.Play.WindowItems{
        window_id: 0,
        slots: List.duplicate(nil, 46)
      })

    {:next_state, :spawn, data, [{:next_event, :internal, nil}]}
  end

  def join(:enter, _, data) do
    {:keep_state, data}
  end

  def spawn(:internal, _, data) do
    protocol = data.protocol

    for r <- 0..32 do
      for x <- -r..r do
        for z <- -r..r do
          if (x * x + z * z <= r * r and x * x + z * z > (r - 1) * (r - 1)) or r == 0 do
            chunk = Minecraft.World.get_chunk(x, z)

            :ok =
              Protocol.send_packet(protocol, %Server.Play.ChunkData{
                chunk_x: x,
                chunk_z: z,
                chunk: chunk
              })
          end
        end
      end
    end

    {:next_state, :ready, data, [{:state_timeout, 1000, :keepalive}]}
  end

  def spawn(:enter, _, data) do
    {:keep_state, data}
  end

  def ready(:enter, _, data) do
    {:keep_state, data}
  end

  def ready(:state_timeout, :keepalive, data) do
    now = System.system_time(:millisecond)

    if now - data.last_keepalive_ack > @keepalive_timeout_ms do
      {:stop, :normal, data}
    else
      :ok =
        Protocol.send_packet(data.protocol, %Server.Play.KeepAlive{keep_alive_id: now})

      {:keep_state, data, [{:state_timeout, 1_000, :keepalive}]}
    end
  end

  def ready(:info, {:keepalive_ack, _id}, data) do
    {:keep_state, %{data | last_keepalive_ack: System.system_time(:millisecond)}}
  end
end
