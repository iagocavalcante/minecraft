defmodule Minecraft.Bedrock.BlockHash do
  @moduledoc """
  Network block hashes for Bedrock Edition.

  When StartGame sets `UseBlockNetworkIDHashes = true`, block runtime IDs on
  the wire are not indices into the version-specific canonical block palette,
  but a stable 32-bit FNV-1a hash of the block state's little-endian NBT
  serialization. This makes runtime IDs independent of the game version, so
  the server needs no per-version palette data.

  Algorithm (mirrors dragonfly `server/world/network_block_hash.go`):

    * `minecraft:unknown` is special-cased to `0xFFFFFFFE`.
    * Otherwise, serialize a little-endian NBT compound (empty root name)
      containing `name` (TAG_String) and `states` (TAG_Compound with keys in
      lexicographic order), then hash the bytes with FNV-1a 32.
  """
  import Bitwise

  @fnv_offset_basis 2_166_136_261
  @fnv_prime 16_777_619

  @typedoc """
  A block state property value: `{:byte, 0..255}`, `{:short, integer}`,
  `{:int, integer}`, or a string.
  """
  @type state_value :: {:byte, 0..255} | {:short, integer} | {:int, integer} | String.t()

  @doc """
  Computes the network block hash for a block state.

  States are given as a map of property name to `t:state_value/0`. Booleans in
  vanilla block states are TAG_Byte 0/1, so pass `{:byte, 0}` / `{:byte, 1}`.

  ## Examples

      iex> Minecraft.Bedrock.BlockHash.hash("minecraft:unknown", %{})
      0xFFFFFFFE
  """
  @spec hash(String.t(), %{optional(String.t()) => state_value}) :: 0..0xFFFFFFFF
  def hash("minecraft:unknown", _states), do: 0xFFFFFFFE

  def hash(name, states) when is_binary(name) and is_map(states) do
    states
    |> serialize(name)
    |> fnv1a32()
  end

  @doc """
  Like `hash/2`, but reinterpreted as a signed 32-bit integer — the form the
  wire protocol expects (palette entries are zigzag varint32).
  """
  @spec signed_hash(String.t(), %{optional(String.t()) => state_value}) :: integer
  def signed_hash(name, states) do
    <<signed::32-signed>> = <<hash(name, states)::32>>
    signed
  end

  defp serialize(states, name) do
    sorted_states = Enum.sort_by(states, fn {key, _} -> key end)

    IO.iodata_to_binary([
      # Root TAG_Compound with empty name
      <<10, 0, 0>>,
      # name: TAG_String
      <<8>>,
      str("name"),
      str(name),
      # states: TAG_Compound
      <<10>>,
      str("states"),
      Enum.map(sorted_states, &serialize_state/1),
      # TAG_End for states, TAG_End for root
      <<0, 0>>
    ])
  end

  defp serialize_state({key, {:byte, v}}) when v in 0..255 do
    [<<1>>, str(key), <<v::8>>]
  end

  defp serialize_state({key, {:short, v}}) do
    [<<2>>, str(key), <<v::16-little>>]
  end

  defp serialize_state({key, {:int, v}}) do
    [<<3>>, str(key), <<v::32-little>>]
  end

  defp serialize_state({key, v}) when is_binary(v) do
    [<<8>>, str(key), str(v)]
  end

  defp str(s), do: <<byte_size(s)::16-little, s::binary>>

  defp fnv1a32(data), do: fnv1a32(data, @fnv_offset_basis)

  defp fnv1a32(<<>>, acc), do: acc

  defp fnv1a32(<<byte, rest::binary>>, acc) do
    fnv1a32(rest, bxor(acc, byte) * @fnv_prime &&& 0xFFFFFFFF)
  end
end
