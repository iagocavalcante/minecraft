defmodule Minecraft.Bedrock.RakNet.Frame do
  @moduledoc """
  RakNet frame (capsule) within a FrameSet datagram.
  Handles reliability headers and split (fragmentation) info.
  """
  import Bitwise

  defstruct reliability: 0,
            reliable_index: nil,
            sequenced_index: nil,
            order_index: nil,
            order_channel: nil,
            split: nil,
            body: <<>>

  @type t :: %__MODULE__{}

  @spec encode(t) :: binary
  def encode(%__MODULE__{} = frame) do
    is_split = if frame.split, do: 1, else: 0
    flags = frame.reliability <<< 5 ||| is_split <<< 4
    body_bit_len = byte_size(frame.body) * 8

    io = [<<flags::8, body_bit_len::16>>]

    # Reliable index for types 2,3,4,6,7
    io =
      if frame.reliability in [2, 3, 4, 6, 7] do
        io ++ [<<frame.reliable_index || 0::24-little>>]
      else
        io
      end

    # Sequenced index for types 1,4
    io =
      if frame.reliability in [1, 4] do
        io ++ [<<frame.sequenced_index || 0::24-little>>]
      else
        io
      end

    # Order index + channel for types 1,3,4,7
    io =
      if frame.reliability in [1, 3, 4, 7] do
        io ++ [<<frame.order_index || 0::24-little, frame.order_channel || 0::8>>]
      else
        io
      end

    # Split info
    io =
      if frame.split do
        %{count: count, id: id, index: index} = frame.split
        io ++ [<<count::32, id::16, index::32>>]
      else
        io
      end

    (io ++ [frame.body]) |> IO.iodata_to_binary()
  end

  @spec decode(binary) :: {t, rest :: binary}
  def decode(<<flags::8, body_bit_len::16, rest::binary>>) do
    reliability = flags >>> 5
    is_split = flags >>> 4 &&& 1
    body_len = div(body_bit_len, 8)

    {reliable_index, rest} =
      if reliability in [2, 3, 4, 6, 7] do
        <<idx::24-little, rest::binary>> = rest
        {idx, rest}
      else
        {nil, rest}
      end

    {sequenced_index, rest} =
      if reliability in [1, 4] do
        <<idx::24-little, rest::binary>> = rest
        {idx, rest}
      else
        {nil, rest}
      end

    {order_index, order_channel, rest} =
      if reliability in [1, 3, 4, 7] do
        <<idx::24-little, channel::8, rest::binary>> = rest
        {idx, channel, rest}
      else
        {nil, nil, rest}
      end

    {split, rest} =
      if is_split == 1 do
        <<count::32, id::16, index::32, rest::binary>> = rest
        {%{count: count, id: id, index: index}, rest}
      else
        {nil, rest}
      end

    <<body::binary-size(body_len), rest::binary>> = rest

    frame = %__MODULE__{
      reliability: reliability,
      reliable_index: reliable_index,
      sequenced_index: sequenced_index,
      order_index: order_index,
      order_channel: order_channel,
      split: split,
      body: body
    }

    {frame, rest}
  end
end
