defmodule Minecraft.Bedrock.RakNet.FrameTest do
  use ExUnit.Case, async: true
  alias Minecraft.Bedrock.RakNet.Frame

  describe "unreliable frame (reliability 0)" do
    test "encode and decode round-trip" do
      frame = %Frame{reliability: 0, body: <<1, 2, 3, 4>>}
      encoded = Frame.encode(frame)
      {decoded, ""} = Frame.decode(encoded)
      assert decoded.reliability == 0
      assert decoded.body == <<1, 2, 3, 4>>
      assert decoded.reliable_index == nil
      assert decoded.split == nil
    end
  end

  describe "reliable ordered frame (reliability 3)" do
    test "encode and decode round-trip" do
      frame = %Frame{
        reliability: 3,
        reliable_index: 42,
        order_index: 7,
        order_channel: 0,
        body: <<"hello">>
      }

      encoded = Frame.encode(frame)
      {decoded, ""} = Frame.decode(encoded)
      assert decoded.reliability == 3
      assert decoded.reliable_index == 42
      assert decoded.order_index == 7
      assert decoded.order_channel == 0
      assert decoded.body == "hello"
    end
  end

  describe "split frame" do
    test "encode and decode with split info" do
      frame = %Frame{
        reliability: 3,
        reliable_index: 1,
        order_index: 0,
        order_channel: 0,
        split: %{count: 4, id: 1, index: 2},
        body: <<"chunk">>
      }

      encoded = Frame.encode(frame)
      {decoded, ""} = Frame.decode(encoded)
      assert decoded.split == %{count: 4, id: 1, index: 2}
      assert decoded.body == "chunk"
    end
  end

  describe "multiple frames back-to-back" do
    test "decode two consecutive frames" do
      f1 = %Frame{reliability: 0, body: <<"aaa">>}
      f2 = %Frame{reliability: 0, body: <<"bbb">>}
      data = Frame.encode(f1) <> Frame.encode(f2)

      {d1, rest} = Frame.decode(data)
      {d2, ""} = Frame.decode(rest)

      assert d1.body == "aaa"
      assert d2.body == "bbb"
    end
  end
end
