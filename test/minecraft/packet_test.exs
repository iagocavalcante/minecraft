defmodule Minecraft.PacketTest do
  use ExUnit.Case, async: true
  import Minecraft.Packet

  describe "varints" do
    test "basics" do
      assert {0, ""} = decode_varint(<<0>>)
      assert {1, ""} = decode_varint(<<1>>)
      assert {2, ""} = decode_varint(<<2>>)
      assert <<0>> = encode_varint(0)
      assert <<1>> = encode_varint(1)
      assert <<2>> = encode_varint(2)
    end

    test "first breakpoint" do
      assert {127, ""} = decode_varint(<<0x7F>>)
      assert {128, ""} = decode_varint(<<0x80, 0x01>>)
      assert {255, ""} = decode_varint(<<0xFF, 0x01>>)
      assert <<0x7F>> = encode_varint(127)
      assert <<0x80, 0x01>> = encode_varint(128)
      assert <<0xFF, 0x01>> = encode_varint(255)
    end

    test "limits" do
      assert {2_147_483_647, ""} = decode_varint(<<0xFF, 0xFF, 0xFF, 0xFF, 0x07>>)
      assert {-1, ""} = decode_varint(<<0xFF, 0xFF, 0xFF, 0xFF, 0x0F>>)
      assert {-2_147_483_648, ""} = decode_varint(<<0x80, 0x80, 0x80, 0x80, 0x08>>)
      assert <<0xFF, 0xFF, 0xFF, 0xFF, 0x07>> = encode_varint(2_147_483_647)
      assert <<0xFF, 0xFF, 0xFF, 0xFF, 0x0F>> = encode_varint(-1)
      assert <<0x80, 0x80, 0x80, 0x80, 0x08>> = encode_varint(-2_147_483_648)
    end

    test "extra data" do
      assert {0, <<1, 2, 3>>} = decode_varint(<<0, 1, 2, 3>>)
      assert {255, <<1, 2, 3>>} = decode_varint(<<0xFF, 0x01, 1, 2, 3>>)
      assert {-1, <<1, 2, 3>>} = decode_varint(<<0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 1, 2, 3>>)
    end

    test "errors" do
      assert {:error, :too_short} = decode_varint(<<0xFF>>)
      assert {:error, :too_long} = decode_varint(<<0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>)
      assert {:error, :too_large} = encode_varint(2_147_483_648)
      assert {:error, :too_large} = encode_varint(-2_147_483_649)
    end
  end

  describe "varlongs" do
    test "basics" do
      assert {0, ""} = decode_varlong(<<0>>)
      assert {1, ""} = decode_varlong(<<1>>)
      assert {2, ""} = decode_varlong(<<2>>)
    end

    test "first breakpoint" do
      assert {127, ""} = decode_varlong(<<0x7F>>)
      assert {128, ""} = decode_varlong(<<0x80, 0x01>>)
      assert {255, ""} = decode_varlong(<<0xFF, 0x01>>)
    end

    test "limits" do
      assert {9_223_372_036_854_775_807, ""} =
               decode_varlong(<<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F>>)

      assert {-1, ""} =
               decode_varlong(<<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01>>)

      assert {-2_147_483_648, ""} =
               decode_varlong(<<0x80, 0x80, 0x80, 0x80, 0xF8, 0xFF, 0xFF, 0xFF, 0xFF, 0x01>>)

      assert {-9_223_372_036_854_775_808, ""} =
               decode_varlong(<<0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01>>)
    end

    test "extra data" do
      assert {0, <<1, 2, 3>>} = decode_varlong(<<0, 1, 2, 3>>)
      assert {255, <<1, 2, 3>>} = decode_varlong(<<0xFF, 0x01, 1, 2, 3>>)

      assert {-1, <<1, 2, 3>>} =
               decode_varlong(
                 <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 1, 2, 3>>
               )
    end

    test "errors" do
      assert {:error, :too_short} = decode_varlong(<<0xFF>>)

      assert {:error, :too_long} =
               decode_varlong(<<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>)
    end
  end

  describe "strings" do
    test "basics" do
      assert {"", ""} = decode_string(<<0>>)
      assert {"a", ""} = decode_string(<<1, "a">>)
      assert {"ab", ""} = decode_string(<<2, "ab">>)
      assert <<0>> = encode_string("")
      assert <<1, "a">> = encode_string("a")
      assert <<2, "ab">> = encode_string("ab")
    end

    test "larger strings" do
      s = String.duplicate("a", 127)
      assert <<0x7F, s::binary>> == encode_string(s)
      assert {s, ""} == decode_string(encode_string(s))
      s = String.duplicate("a", 128)
      assert <<0x80, 0x01, s::binary>> == encode_string(s)
      assert {s, ""} == decode_string(encode_string(s))
    end

    test "extra data" do
      assert {"", <<1, 2, 3>>} = decode_string(<<0, 1, 2, 3>>)
      assert {"a", <<1, 2, 3>>} = decode_string(<<1, "a", 1, 2, 3>>)
    end
  end

  test "bools" do
    assert {false, ""} = decode_bool(<<0>>)
    assert {true, ""} = decode_bool(<<1>>)
    assert {false, <<1, 2, 3>>} = decode_bool(<<0, 1, 2, 3>>)
    assert {true, <<1, 2, 3>>} = decode_bool(<<1, 1, 2, 3>>)
    assert <<0>> = encode_bool(false)
    assert <<1>> = encode_bool(true)
  end

  describe "Server.Login.Disconnect" do
    test "serialize and deserialize round-trip" do
      reason = Jason.encode!(%{text: "Bad verify token"})
      packet = %Minecraft.Packet.Server.Login.Disconnect{reason: reason}
      {0x00, binary} = Minecraft.Packet.Server.Login.Disconnect.serialize(packet)
      {deserialized, ""} = Minecraft.Packet.Server.Login.Disconnect.deserialize(binary)
      assert deserialized.reason == reason
    end
  end

  describe "Client.Play.Player" do
    test "serialize and deserialize round-trip" do
      for on_ground <- [true, false] do
        packet = %Minecraft.Packet.Client.Play.Player{on_ground: on_ground}
        {0x0C, binary} = Minecraft.Packet.Client.Play.Player.serialize(packet)
        {deserialized, ""} = Minecraft.Packet.Client.Play.Player.deserialize(binary)
        assert deserialized.on_ground == on_ground
      end
    end
  end

  describe "Client.Play.ChatMessage" do
    test "serialize and deserialize round-trip" do
      packet = %Minecraft.Packet.Client.Play.ChatMessage{message: "Hello world!"}
      {0x02, binary} = Minecraft.Packet.Client.Play.ChatMessage.serialize(packet)
      {deserialized, ""} = Minecraft.Packet.Client.Play.ChatMessage.deserialize(binary)
      assert deserialized.message == "Hello world!"
    end
  end

  describe "Server.Play.ChatMessage" do
    test "serialize and deserialize round-trip" do
      json = Jason.encode!(%{text: "Hello from server"})
      packet = %Minecraft.Packet.Server.Play.ChatMessage{json_data: json, position: 1}
      {0x0F, binary} = Minecraft.Packet.Server.Play.ChatMessage.serialize(packet)
      {deserialized, ""} = Minecraft.Packet.Server.Play.ChatMessage.deserialize(binary)
      assert deserialized.json_data == json
      assert deserialized.position == 1
    end
  end

  describe "Server.Play.WindowItems" do
    test "serialize empty inventory" do
      packet = %Minecraft.Packet.Server.Play.WindowItems{
        window_id: 0,
        slots: List.duplicate(nil, 46)
      }

      {0x14, binary} = Minecraft.Packet.Server.Play.WindowItems.serialize(packet)
      assert byte_size(binary) == 1 + 2 + 46 * 2

      {deserialized, ""} = Minecraft.Packet.Server.Play.WindowItems.deserialize(binary)
      assert deserialized.window_id == 0
      assert length(deserialized.slots) == 46
      assert Enum.all?(deserialized.slots, &is_nil/1)
    end
  end

  describe "Server.Play.TimeUpdate" do
    test "serialize and deserialize round-trip" do
      packet = %Minecraft.Packet.Server.Play.TimeUpdate{world_age: 1000, time_of_day: 6000}
      {0x47, binary} = Minecraft.Packet.Server.Play.TimeUpdate.serialize(packet)
      {deserialized, ""} = Minecraft.Packet.Server.Play.TimeUpdate.deserialize(binary)
      assert deserialized.world_age == 1000
      assert deserialized.time_of_day == 6000
    end
  end
end
