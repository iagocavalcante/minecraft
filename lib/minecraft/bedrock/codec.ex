defmodule Minecraft.Bedrock.Codec do
  @moduledoc """
  Bedrock batch packet codec: 0xFE header + compression + varuint length framing.

  Pre-compression:  0xFE | sub_packets...
  Post-compression: 0xFE | algo_byte | compressed_payload
    algo_byte: 0x00=zlib, 0x01=snappy, 0xFF=none/raw
  """
  import Bitwise

  # --- Encode ---

  @doc "Encode batch with zlib compression (post-NetworkSettings)"
  @spec encode_batch([binary]) :: binary
  def encode_batch(packets) do
    inner = encode_sub_packets(packets)
    z = :zlib.open()
    :ok = :zlib.deflateInit(z)
    compressed = :zlib.deflate(z, inner, :finish) |> IO.iodata_to_binary()
    :zlib.deflateEnd(z)
    :zlib.close(z)
    # 0xFE + algo byte (0x00 = deflate) + compressed
    <<0xFE, 0x00, compressed::binary>>
  end

  @doc "Encode batch without compression (pre-NetworkSettings)"
  @spec encode_batch_uncompressed([binary]) :: binary
  def encode_batch_uncompressed(packets) do
    inner = encode_sub_packets(packets)
    # 0xFE + raw sub-packets (no algo byte before compression is enabled)
    <<0xFE, inner::binary>>
  end

  defp encode_sub_packets(packets) do
    Enum.map(packets, fn pkt ->
      <<encode_varuint(byte_size(pkt))::binary, pkt::binary>>
    end)
    |> IO.iodata_to_binary()
  end

  # --- Decode ---

  @spec decode_batch(binary, boolean) :: {:ok, [binary]} | {:error, term}
  def decode_batch(data, compression_enabled \\ false)

  # Pre-compression: 0xFE followed directly by sub-packets (no algo byte)
  def decode_batch(<<0xFE, rest::binary>>, false) do
    try do
      {:ok, decode_sub_packets(rest, [])}
    rescue
      _ -> {:error, :decode_failed}
    end
  end

  # Post-compression: 0xFE + algo_byte + payload
  def decode_batch(<<0xFE, algo::8, rest::binary>>, true) do
    decompressed =
      case algo do
        0x00 ->
          # Zlib/deflate — try multiple decompression methods
          zlib_inflate(rest)

        0xFF ->
          # No compression
          rest

        _ ->
          rest
      end

    try do
      {:ok, decode_sub_packets(decompressed, [])}
    rescue
      _ -> {:error, :decode_failed}
    end
  end

  def decode_batch(_, _), do: {:error, :not_a_batch}

  # --- Varuint encoding (unsigned LEB128) ---

  @spec encode_varuint(non_neg_integer) :: binary
  def encode_varuint(value) when value < 128, do: <<value::8>>

  def encode_varuint(value) do
    <<1::1, value &&& 0x7F::7, encode_varuint(value >>> 7)::binary>>
  end

  @spec decode_varuint(binary) :: {non_neg_integer, binary}
  def decode_varuint(data), do: decode_varuint(data, 0, 0)

  defp decode_varuint(<<0::1, val::7, rest::binary>>, shift, acc) do
    {acc ||| val <<< shift, rest}
  end

  defp decode_varuint(<<1::1, val::7, rest::binary>>, shift, acc) do
    decode_varuint(rest, shift + 7, acc ||| val <<< shift)
  end

  # --- Game packet header ---

  @spec encode_packet_header(non_neg_integer) :: binary
  def encode_packet_header(packet_id) do
    encode_varuint(packet_id <<< 2)
  end

  @spec decode_packet_header(binary) :: {non_neg_integer, binary}
  def decode_packet_header(data) do
    {header, rest} = decode_varuint(data)
    {header >>> 2, rest}
  end

  # --- Decompression ---

  defp zlib_inflate(data) do
    # Try :zlib.uncompress first (expects zlib header)
    try do
      :zlib.uncompress(data)
    rescue
      _ ->
        # Try raw deflate (no zlib header) using manual inflate
        z = :zlib.open()

        try do
          :ok = :zlib.inflateInit(z)
          result = :zlib.inflate(z, data) |> IO.iodata_to_binary()
          :zlib.inflateEnd(z)
          result
        rescue
          _ ->
            # Try raw deflate with -15 window bits (no header)
            z2 = :zlib.open()

            try do
              :ok = :zlib.inflateInit(z2, -15)
              result = :zlib.inflate(z2, data) |> IO.iodata_to_binary()
              :zlib.inflateEnd(z2)
              result
            after
              :zlib.close(z2)
            end
        after
          :zlib.close(z)
        end
    end
  end

  # --- Private ---

  defp decode_sub_packets("", acc), do: Enum.reverse(acc)

  defp decode_sub_packets(data, acc) do
    {len, rest} = decode_varuint(data)
    <<packet::binary-size(len), rest::binary>> = rest
    decode_sub_packets(rest, [packet | acc])
  end
end
