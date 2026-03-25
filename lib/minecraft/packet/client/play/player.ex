defmodule Minecraft.Packet.Client.Play.Player do
  @moduledoc false
  import Minecraft.Packet, only: [encode_bool: 1, decode_bool: 1]

  @type t :: %__MODULE__{packet_id: 0x0C, on_ground: boolean}

  defstruct packet_id: 0x0C,
            on_ground: true

  @spec serialize(t) :: {packet_id :: 0x0C, binary}
  def serialize(%__MODULE__{on_ground: on_ground}) do
    {0x0C, encode_bool(on_ground)}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    {on_ground, rest} = decode_bool(data)
    {%__MODULE__{on_ground: on_ground}, rest}
  end
end
