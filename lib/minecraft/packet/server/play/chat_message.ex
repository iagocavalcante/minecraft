defmodule Minecraft.Packet.Server.Play.ChatMessage do
  @moduledoc false
  import Minecraft.Packet, only: [encode_string: 1, decode_string: 1]

  @type t :: %__MODULE__{packet_id: 0x0F, json_data: String.t(), position: 0 | 1 | 2}

  defstruct packet_id: 0x0F,
            json_data: nil,
            position: 0

  @spec serialize(t) :: {packet_id :: 0x0F, binary}
  def serialize(%__MODULE__{json_data: json_data, position: position}) do
    {0x0F, <<encode_string(json_data)::binary, position::8>>}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    {json_data, rest} = decode_string(data)
    <<position::8, rest::binary>> = rest
    {%__MODULE__{json_data: json_data, position: position}, rest}
  end
end
