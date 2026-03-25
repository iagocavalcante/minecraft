defmodule Minecraft.Packet.Server.Play.TimeUpdate do
  @moduledoc false

  @type t :: %__MODULE__{packet_id: 0x47, world_age: integer, time_of_day: integer}

  defstruct packet_id: 0x47,
            world_age: 0,
            time_of_day: 6000

  @spec serialize(t) :: {packet_id :: 0x47, binary}
  def serialize(%__MODULE__{world_age: world_age, time_of_day: time_of_day}) do
    {0x47, <<world_age::64-signed, time_of_day::64-signed>>}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    <<world_age::64-signed, time_of_day::64-signed, rest::binary>> = data
    {%__MODULE__{world_age: world_age, time_of_day: time_of_day}, rest}
  end
end
