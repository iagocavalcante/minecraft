defmodule Minecraft.Packet.Client.Play.ChatMessage do
  @moduledoc false
  import Minecraft.Packet, only: [encode_string: 1, decode_string: 1]

  @type t :: %__MODULE__{packet_id: 0x02, message: String.t()}

  defstruct packet_id: 0x02,
            message: ""

  @spec serialize(t) :: {packet_id :: 0x02, binary}
  def serialize(%__MODULE__{message: message}) do
    {0x02, encode_string(message)}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    {message, rest} = decode_string(data)
    {%__MODULE__{message: message}, rest}
  end
end
