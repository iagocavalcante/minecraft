defmodule Minecraft.Packet.Server.Login.Disconnect do
  @moduledoc false
  import Minecraft.Packet, only: [encode_string: 1, decode_string: 1]

  @type t :: %__MODULE__{packet_id: 0x00, reason: String.t()}

  defstruct packet_id: 0x00,
            reason: nil

  @spec serialize(t) :: {packet_id :: 0x00, binary}
  def serialize(%__MODULE__{reason: reason}) do
    {0x00, <<encode_string(reason)::binary>>}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    {reason, rest} = decode_string(data)
    {%__MODULE__{reason: reason}, rest}
  end
end
