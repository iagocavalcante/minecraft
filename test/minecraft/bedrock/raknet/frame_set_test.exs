defmodule Minecraft.Bedrock.RakNet.FrameSetTest do
  use ExUnit.Case, async: true
  alias Minecraft.Bedrock.RakNet.{FrameSet, Frame}

  describe "FrameSet encode/decode" do
    test "single frame round-trip" do
      frames = [
        %Frame{
          reliability: 3,
          reliable_index: 0,
          order_index: 0,
          order_channel: 0,
          body: <<"hello">>
        }
      ]

      encoded = FrameSet.encode(0, frames)
      assert {:frame_set, 0, decoded_frames} = FrameSet.decode(encoded)
      assert length(decoded_frames) == 1
      assert hd(decoded_frames).body == "hello"
    end

    test "multiple frames in one datagram" do
      frames = [
        %Frame{reliability: 0, body: <<"aaa">>},
        %Frame{reliability: 0, body: <<"bbb">>}
      ]

      encoded = FrameSet.encode(5, frames)
      assert {:frame_set, 5, decoded_frames} = FrameSet.decode(encoded)
      assert length(decoded_frames) == 2
      assert Enum.at(decoded_frames, 0).body == "aaa"
      assert Enum.at(decoded_frames, 1).body == "bbb"
    end

    test "sequence number preserved" do
      frames = [%Frame{reliability: 0, body: <<1>>}]
      encoded = FrameSet.encode(12345, frames)
      assert {:frame_set, 12345, _} = FrameSet.decode(encoded)
    end
  end

  describe "ACK" do
    test "single sequence" do
      encoded = FrameSet.encode_ack([5])
      assert {:ack, [5]} = FrameSet.decode(encoded)
    end

    test "consecutive range" do
      encoded = FrameSet.encode_ack([3, 4, 5])
      assert {:ack, [3, 4, 5]} = FrameSet.decode(encoded)
    end

    test "mixed singles and ranges" do
      encoded = FrameSet.encode_ack([1, 2, 3, 7, 10, 11])
      assert {:ack, [1, 2, 3, 7, 10, 11]} = FrameSet.decode(encoded)
    end
  end

  describe "NAK" do
    test "single NAK" do
      encoded = FrameSet.encode_nak([7])
      assert {:nak, [7]} = FrameSet.decode(encoded)
    end

    test "range NAK" do
      encoded = FrameSet.encode_nak([2, 3, 4])
      assert {:nak, [2, 3, 4]} = FrameSet.decode(encoded)
    end
  end
end
