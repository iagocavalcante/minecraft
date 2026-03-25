defmodule Minecraft.Bedrock.RakNetTest do
  use ExUnit.Case, async: true
  alias Minecraft.Bedrock.RakNet

  @magic <<0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE, 0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34,
           0x56, 0x78>>

  describe "Unconnected Ping/Pong" do
    test "decode unconnected ping" do
      data = <<0x01, 12345::64, @magic::binary, 99::64>>
      assert {:unconnected_ping, %{timestamp: 12345, client_guid: 99}} = RakNet.decode(data)
    end

    test "encode unconnected pong" do
      pong =
        RakNet.encode_unconnected_pong(
          12345,
          42,
          "MCPE;Test;685;1.21.0;0;20;42;Level;Survival;1;19132;19133"
        )

      assert <<0x1C, 12345::64, 42::64, @magic::binary, _rest::binary>> = pong
    end
  end

  describe "Open Connection Request/Reply 1" do
    test "decode OCR1" do
      padding = :binary.copy(<<0>>, 1400)
      data = <<0x05, @magic::binary, 11::8, padding::binary>>

      assert {:open_connection_request_1, %{protocol_version: 11, mtu_size: mtu}} =
               RakNet.decode(data)

      assert mtu == 1418
    end

    test "encode OC Reply 1" do
      reply = RakNet.encode_open_connection_reply_1(42, 1400)
      assert <<0x06, @magic::binary, 42::64, 0x00, 1400::16>> = reply
    end
  end

  describe "Open Connection Request/Reply 2" do
    test "decode OCR2" do
      addr = RakNet.encode_address({127, 0, 0, 1}, 19132)
      data = <<0x07, @magic::binary, addr::binary, 1400::16, 99::64>>

      assert {:open_connection_request_2, %{mtu_size: 1400, client_guid: 99}} =
               RakNet.decode(data)
    end

    test "encode OC Reply 2" do
      reply = RakNet.encode_open_connection_reply_2(42, {127, 0, 0, 1}, 19132, 1400)
      assert <<0x08, @magic::binary, 42::64, _addr::binary-7, 1400::16, 0x00>> = reply
    end
  end

  describe "address encoding" do
    test "round-trip" do
      encoded = RakNet.encode_address({192, 168, 1, 100}, 25565)
      assert {{192, 168, 1, 100}, 25565} = RakNet.decode_address(encoded)
    end
  end
end
