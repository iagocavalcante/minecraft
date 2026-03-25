defmodule Minecraft.Bedrock.RakNet do
  @moduledoc """
  RakNet offline packet codec for Bedrock Edition.
  Pure functions — no processes, no state.
  """
  import Bitwise

  @magic <<0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE, 0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34,
           0x56, 0x78>>

  @raknet_protocol_version 11

  # --- Decode ---

  def decode(<<0x01, timestamp::64, @magic::binary, client_guid::64>>) do
    {:unconnected_ping, %{timestamp: timestamp, client_guid: client_guid}}
  end

  def decode(<<0x05, @magic::binary, protocol_version::8, padding::binary>>) do
    mtu_size = 1 + 16 + 1 + byte_size(padding)
    {:open_connection_request_1, %{protocol_version: protocol_version, mtu_size: mtu_size}}
  end

  def decode(<<0x07, @magic::binary, address::binary-7, mtu_size::16, client_guid::64>>) do
    {ip, port} = decode_address(address)

    {:open_connection_request_2,
     %{server_address: {ip, port}, mtu_size: mtu_size, client_guid: client_guid}}
  end

  def decode(<<id, _::binary>>) do
    {:unknown, id}
  end

  # --- Encode ---

  def encode_unconnected_pong(client_timestamp, server_guid, motd_string) do
    motd_len = byte_size(motd_string)

    <<0x1C, client_timestamp::64, server_guid::64, @magic::binary, motd_len::16,
      motd_string::binary>>
  end

  def encode_open_connection_reply_1(server_guid, mtu_size) do
    <<0x06, @magic::binary, server_guid::64, 0x00, mtu_size::16>>
  end

  def encode_open_connection_reply_2(server_guid, client_ip, client_port, mtu_size) do
    address = encode_address(client_ip, client_port)
    <<0x08, @magic::binary, server_guid::64, address::binary, mtu_size::16, 0x00>>
  end

  def encode_incompatible_protocol(server_guid) do
    <<0x1A, @raknet_protocol_version::8, @magic::binary, server_guid::64>>
  end

  # --- Address encoding (IPv4 only) ---
  # RakNet encodes IPv4 addresses with each byte inverted (bitwise NOT)

  def encode_address({a, b, c, d}, port) do
    <<4::8, bnot(a) &&& 0xFF::8, bnot(b) &&& 0xFF::8, bnot(c) &&& 0xFF::8, bnot(d) &&& 0xFF::8,
      port::16>>
  end

  def decode_address(<<4::8, a::8, b::8, c::8, d::8, port::16>>) do
    {{bnot(a) &&& 0xFF, bnot(b) &&& 0xFF, bnot(c) &&& 0xFF, bnot(d) &&& 0xFF}, port}
  end

  # --- Helpers ---

  def magic, do: @magic
  def protocol_version, do: @raknet_protocol_version
end
