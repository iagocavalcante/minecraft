defmodule Minecraft.Bedrock.RakNet.FrameSet do
  @moduledoc """
  RakNet FrameSet (datagram), ACK, and NAK codec.

  A FrameSet carries one or more Frames plus a 3-byte sequence number.
  ACK (0xC0) and NAK (0xA0) carry lists of acknowledged/missing sequence numbers.
  """
  import Bitwise
  alias Minecraft.Bedrock.RakNet.Frame

  # --- Decode ---

  def decode(<<0xC0, rest::binary>>), do: decode_ack_nak(:ack, rest)
  def decode(<<0xA0, rest::binary>>), do: decode_ack_nak(:nak, rest)

  def decode(<<flags::8, seq::24-little, rest::binary>>) when (flags &&& 0x80) == 0x80 do
    frames = decode_frames(rest, [])
    {:frame_set, seq, frames}
  end

  # --- Encode ---

  @spec encode(non_neg_integer, [Frame.t()]) :: binary
  def encode(sequence_number, frames) do
    frame_data = Enum.map(frames, &Frame.encode/1) |> IO.iodata_to_binary()
    <<0x84, sequence_number::24-little, frame_data::binary>>
  end

  @spec encode_ack([non_neg_integer]) :: binary
  def encode_ack(sequences), do: encode_ack_nak(0xC0, sequences)

  @spec encode_nak([non_neg_integer]) :: binary
  def encode_nak(sequences), do: encode_ack_nak(0xA0, sequences)

  # --- Private: Frame decoding ---

  defp decode_frames("", acc), do: Enum.reverse(acc)

  defp decode_frames(data, acc) do
    {frame, rest} = Frame.decode(data)
    decode_frames(rest, [frame | acc])
  end

  # --- Private: ACK/NAK ---

  defp encode_ack_nak(id, sequences) do
    sorted = Enum.sort(sequences)
    ranges = to_ranges(sorted)
    record_count = length(ranges)

    records =
      Enum.map(ranges, fn
        {s, s} -> <<1::8, s::24-little>>
        {s, e} -> <<0::8, s::24-little, e::24-little>>
      end)
      |> IO.iodata_to_binary()

    <<id::8, record_count::16, records::binary>>
  end

  defp decode_ack_nak(type, <<record_count::16, rest::binary>>) do
    {sequences, _rest} = decode_records(rest, record_count, [])
    {type, Enum.sort(List.flatten(sequences))}
  end

  defp decode_records(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_records(<<1::8, seq::24-little, rest::binary>>, n, acc) do
    decode_records(rest, n - 1, [[seq] | acc])
  end

  defp decode_records(<<0::8, s::24-little, e::24-little, rest::binary>>, n, acc) do
    decode_records(rest, n - 1, [Enum.to_list(s..e) | acc])
  end

  # Convert sorted list to ranges: [1,2,3,5,6] -> [{1,3},{5,6}]
  defp to_ranges([]), do: []
  defp to_ranges([h | t]), do: to_ranges(t, h, h, [])
  defp to_ranges([], s, e, acc), do: Enum.reverse([{s, e} | acc])
  defp to_ranges([h | t], s, e, acc) when h == e + 1, do: to_ranges(t, s, h, acc)
  defp to_ranges([h | t], s, e, acc), do: to_ranges(t, h, h, [{s, e} | acc])
end
