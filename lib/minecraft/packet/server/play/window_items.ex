defmodule Minecraft.Packet.Server.Play.WindowItems do
  @moduledoc false

  @type slot :: nil | {item_id :: integer, count :: integer, damage :: integer, nbt :: binary}
  @type t :: %__MODULE__{packet_id: 0x14, window_id: integer, slots: [slot]}

  defstruct packet_id: 0x14,
            window_id: 0,
            slots: []

  @spec serialize(t) :: {packet_id :: 0x14, binary}
  def serialize(%__MODULE__{window_id: window_id, slots: slots}) do
    count = length(slots)
    slot_data = Enum.map(slots, &serialize_slot/1) |> IO.iodata_to_binary()
    {0x14, <<window_id::8, count::16-signed, slot_data::binary>>}
  end

  defp serialize_slot(nil), do: <<-1::16-signed>>

  defp serialize_slot({item_id, count, damage, nbt}) do
    <<item_id::16-signed, count::8, damage::16-signed, nbt::binary>>
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    <<window_id::8, count::16-signed, rest::binary>> = data
    {slots, rest} = deserialize_slots(rest, count, [])
    {%__MODULE__{window_id: window_id, slots: slots}, rest}
  end

  defp deserialize_slots(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp deserialize_slots(<<-1::16-signed, rest::binary>>, count, acc) do
    deserialize_slots(rest, count - 1, [nil | acc])
  end

  defp deserialize_slots(
         <<item_id::16-signed, count::8, damage::16-signed, rest::binary>>,
         n,
         acc
       ) do
    <<_nbt_end::8, rest::binary>> = rest
    deserialize_slots(rest, n - 1, [{item_id, count, damage, <<0x00>>} | acc])
  end
end
