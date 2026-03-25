defmodule Minecraft.Bedrock.CodecTest do
  use ExUnit.Case, async: true
  alias Minecraft.Bedrock.Codec

  describe "varuint" do
    test "encode/decode small values" do
      for v <- [0, 1, 127] do
        encoded = Codec.encode_varuint(v)
        assert {^v, ""} = Codec.decode_varuint(encoded)
      end
    end

    test "encode/decode larger values" do
      for v <- [128, 255, 300, 65535, 1_000_000] do
        encoded = Codec.encode_varuint(v)
        assert {^v, ""} = Codec.decode_varuint(encoded)
      end
    end
  end

  describe "batch encoding/decoding" do
    test "compressed round-trip" do
      packets = [<<"hello">>, <<"world">>, <<1, 2, 3>>]
      batch = Codec.encode_batch(packets)
      assert <<0xFE, _::binary>> = batch
      assert {:ok, ^packets} = Codec.decode_batch(batch, true)
    end

    test "uncompressed round-trip" do
      packets = [<<"test">>]
      batch = Codec.encode_batch_uncompressed(packets)
      assert <<0xFE, _::binary>> = batch
      assert {:ok, ^packets} = Codec.decode_batch(batch, false)
    end

    test "single packet" do
      packets = [<<42>>]
      batch = Codec.encode_batch(packets)
      assert {:ok, [<<42>>]} = Codec.decode_batch(batch, true)
    end

    test "invalid data" do
      assert {:error, :not_a_batch} = Codec.decode_batch(<<0x00, 0x01>>)
    end
  end

  describe "packet header" do
    test "encode/decode packet ID" do
      for id <- [1, 2, 6, 7, 11, 143, 193] do
        encoded = Codec.encode_packet_header(id)
        assert {^id, ""} = Codec.decode_packet_header(encoded)
      end
    end
  end
end
