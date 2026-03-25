# Bedrock Edition Support — Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Get a Minecraft Bedrock Edition mobile client to see the server in the server list, connect, and spawn in a flat world — offline mode, no encryption.

**Architecture:** Add a parallel UDP listener (port 19132) alongside the existing TCP listener (port 25565). The Bedrock stack has 3 layers: RakNet (UDP reliability), Batch framing (compression + length-prefixed packets), and Bedrock game protocol. Each layer is a separate module. One GenServer per Bedrock connection manages the RakNet session + Bedrock state machine. The existing Java Edition server is untouched.

**Tech Stack:** Elixir GenServer + `:gen_udp`, zlib for compression, RakNet protocol over UDP, Bedrock Protocol 685+

**Protocol reference:** https://wiki.bedrock.dev/servers/raknet

---

## Architecture Overview

```
lib/minecraft/
├── bedrock/
│   ├── listener.ex          # GenServer — UDP socket on :19132, routes packets
│   ├── session.ex            # GenServer — per-client RakNet + Bedrock state machine
│   ├── raknet.ex             # Pure functions — encode/decode RakNet packets
│   ├── raknet/
│   │   ├── frame.ex          # Frame (capsule) encode/decode
│   │   └── frame_set.ex      # FrameSet datagram encode/decode + ACK/NAK
│   ├── codec.ex              # Pure functions — batch 0xFE wrapper, compression
│   └── packet.ex             # Bedrock game packet encode/decode
```

**Process tree:**

```
Minecraft.Supervisor
├── (existing Java Edition processes)
├── Minecraft.Bedrock.Listener     # GenServer — owns UDP socket
│   └── (routes by client address to sessions)
└── Minecraft.Bedrock.SessionSupervisor  # DynamicSupervisor
    ├── Minecraft.Bedrock.Session #1    # per-client GenServer
    ├── Minecraft.Bedrock.Session #2
    └── ...
```

**Why processes here (Iron Law check):**
- Listener: YES — mutable state (UDP socket), concurrent I/O
- Session: YES — mutable state (RakNet sequence numbers, split reassembly, connection state), fault isolation per client
- SessionSupervisor: YES — dynamic children need supervision

---

## Task Dependency Graph

```
Task 1 (RakNet codec)        ─── standalone
Task 2 (Frame codec)         ─── standalone
Task 3 (FrameSet codec)      ─── depends on Task 2
Task 4 (UDP Listener)        ─── depends on Task 1
Task 5 (Session + handshake) ─── depends on Tasks 1,2,3,4
Task 6 (Batch codec)         ─── standalone
Task 7 (Bedrock packets)     ─── standalone
Task 8 (Login flow)          ─── depends on Tasks 5,6,7
Task 9 (Game start + spawn)  ─── depends on Task 8
Task 10 (Wire into app)      ─── depends on all above
Task 11 (Fly.io deploy)      ─── depends on Task 10
```

Tasks 1, 2, 6, 7 are fully independent and can be parallelized.

---

### Task 1: RakNet Offline Packet Codec

Encode/decode the 6 offline RakNet packets (pre-connection, raw UDP). These are the first thing a Bedrock client sends.

**Files:**
- Create: `lib/minecraft/bedrock/raknet.ex`
- Create: `test/minecraft/bedrock/raknet_test.exs`

**Step 1: Write failing tests**

```elixir
# test/minecraft/bedrock/raknet_test.exs
defmodule Minecraft.Bedrock.RakNetTest do
  use ExUnit.Case, async: true
  alias Minecraft.Bedrock.RakNet

  @magic <<0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE,
           0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78>>

  describe "Unconnected Ping/Pong" do
    test "decode unconnected ping" do
      data = <<0x01, 12345::64, @magic::binary, 99::64>>
      assert {:unconnected_ping, %{timestamp: 12345, client_guid: 99}} = RakNet.decode(data)
    end

    test "encode unconnected pong" do
      pong = RakNet.encode_unconnected_pong(12345, 42, "MCPE;Test;685;1.21.0;0;20;42;Level;Survival;1;19132;19133")
      assert <<0x1C, 12345::64, 42::64, @magic::binary, _rest::binary>> = pong
    end
  end

  describe "Open Connection Request/Reply 1" do
    test "decode OCR1" do
      padding = :binary.copy(<<0>>, 1400)
      data = <<0x05, @magic::binary, 11::8, padding::binary>>
      assert {:open_connection_request_1, %{protocol_version: 11, mtu_size: mtu}} = RakNet.decode(data)
      assert mtu > 1000
    end

    test "encode OC Reply 1" do
      reply = RakNet.encode_open_connection_reply_1(42, 1400)
      assert <<0x06, @magic::binary, 42::64, 0x00, 1400::16>> = reply
    end
  end

  describe "Open Connection Request/Reply 2" do
    test "decode OCR2" do
      data = <<0x07, @magic::binary, 4, 127, 0, 0, 1, 19132::16, 1400::16, 99::64>>
      assert {:open_connection_request_2, %{mtu_size: 1400, client_guid: 99}} = RakNet.decode(data)
    end

    test "encode OC Reply 2" do
      reply = RakNet.encode_open_connection_reply_2(42, {127, 0, 0, 1}, 19132, 1400)
      assert <<0x08, @magic::binary, 42::64, _addr::binary-7, 1400::16, 0x00>> = reply
    end
  end
end
```

**Step 2: Run tests to verify failure**

```bash
mix test test/minecraft/bedrock/raknet_test.exs
```

**Step 3: Implement RakNet codec**

```elixir
# lib/minecraft/bedrock/raknet.ex
defmodule Minecraft.Bedrock.RakNet do
  @moduledoc """
  RakNet offline packet codec for Bedrock Edition.
  Pure functions — no processes, no state.
  """

  @magic <<0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE,
           0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78>>

  @raknet_protocol_version 11

  # --- Decode ---

  def decode(<<0x01, timestamp::64, @magic::binary, client_guid::64>>) do
    {:unconnected_ping, %{timestamp: timestamp, client_guid: client_guid}}
  end

  def decode(<<0x05, @magic::binary, protocol_version::8, padding::binary>>) do
    # MTU = total UDP payload size = 1 (id) + 16 (magic) + 1 (version) + padding
    mtu_size = 1 + 16 + 1 + byte_size(padding)
    {:open_connection_request_1, %{protocol_version: protocol_version, mtu_size: mtu_size}}
  end

  def decode(<<0x07, @magic::binary, address::binary-7, mtu_size::16, client_guid::64>>) do
    {ip, port} = decode_address(address)
    {:open_connection_request_2, %{server_address: {ip, port}, mtu_size: mtu_size, client_guid: client_guid}}
  end

  def decode(<<id, _::binary>>) do
    {:unknown, id}
  end

  # --- Encode ---

  def encode_unconnected_pong(client_timestamp, server_guid, motd_string) do
    motd_len = byte_size(motd_string)
    <<0x1C, client_timestamp::64, server_guid::64, @magic::binary, motd_len::16, motd_string::binary>>
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

  def encode_address({a, b, c, d}, port) do
    <<4::8, bnot(a)::8, bnot(b)::8, bnot(c)::8, bnot(d)::8, port::16>>
  end

  def decode_address(<<4::8, a::8, b::8, c::8, d::8, port::16>>) do
    {{bnot(a) &&& 0xFF, bnot(b) &&& 0xFF, bnot(c) &&& 0xFF, bnot(d) &&& 0xFF}, port}
  end

  # --- Helpers ---

  def magic, do: @magic
  def protocol_version, do: @raknet_protocol_version
end
```

**Step 4: Run tests, commit**

```bash
mix test test/minecraft/bedrock/raknet_test.exs
git add lib/minecraft/bedrock/raknet.ex test/minecraft/bedrock/raknet_test.exs
git commit -m "feat(bedrock): add RakNet offline packet codec"
```

---

### Task 2: RakNet Frame (Capsule) Codec

Encode/decode individual frames within a FrameSet datagram. Handles reliability headers and split info.

**Files:**
- Create: `lib/minecraft/bedrock/raknet/frame.ex`
- Create: `test/minecraft/bedrock/raknet/frame_test.exs`

**Step 1: Write failing tests**

```elixir
# test/minecraft/bedrock/raknet/frame_test.exs
defmodule Minecraft.Bedrock.RakNet.FrameTest do
  use ExUnit.Case, async: true
  alias Minecraft.Bedrock.RakNet.Frame

  describe "unreliable frame" do
    test "encode and decode round-trip" do
      frame = %Frame{reliability: 0, body: <<1, 2, 3, 4>>}
      encoded = Frame.encode(frame)
      {decoded, ""} = Frame.decode(encoded)
      assert decoded.reliability == 0
      assert decoded.body == <<1, 2, 3, 4>>
    end
  end

  describe "reliable ordered frame" do
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
    end
  end
end
```

**Step 2: Implement Frame codec**

```elixir
# lib/minecraft/bedrock/raknet/frame.ex
defmodule Minecraft.Bedrock.RakNet.Frame do
  @moduledoc """
  RakNet frame (capsule) within a FrameSet datagram.
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
    flags = (frame.reliability <<< 5) ||| (is_split <<< 4)
    body_bit_len = byte_size(frame.body) * 8

    header = <<flags::8, body_bit_len::16>>

    header = add_reliability_fields(header, frame)
    header = add_split_fields(header, frame)

    <<header::binary, frame.body::binary>>
  end

  @spec decode(binary) :: {t, rest :: binary}
  def decode(<<flags::8, body_bit_len::16, rest::binary>>) do
    reliability = flags >>> 5
    is_split = (flags >>> 4) &&& 1
    body_len = div(body_bit_len, 8)

    {reliable_index, rest} = decode_reliable_index(reliability, rest)
    {sequenced_index, rest} = decode_sequenced_index(reliability, rest)
    {order_index, order_channel, rest} = decode_order_fields(reliability, rest)
    {split, rest} = decode_split(is_split, rest)

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

  # --- Private helpers ---

  defp add_reliability_fields(header, %{reliability: r} = frame) when r in [2, 3, 4, 6, 7] do
    <<header::binary, frame.reliable_index::24-little>>
  end
  defp add_reliability_fields(header, _), do: header

  defp add_reliability_fields_seq(header, %{reliability: r} = frame) when r in [1, 4] do
    <<header::binary, frame.sequenced_index::24-little>>
  end
  defp add_reliability_fields_seq(header, _), do: header

  # Combine reliability + sequenced in encode
  defp add_reliability_fields(header, %{reliability: r} = frame) when r in [2, 6] do
    <<header::binary, frame.reliable_index::24-little>>
  end
  defp add_reliability_fields(header, %{reliability: r} = frame) when r in [3, 7] do
    <<header::binary, frame.reliable_index::24-little,
      (frame.order_index || 0)::24-little, (frame.order_channel || 0)::8>>
  end
  defp add_reliability_fields(header, %{reliability: r} = frame) when r in [1] do
    <<header::binary, (frame.sequenced_index || 0)::24-little,
      (frame.order_index || 0)::24-little, (frame.order_channel || 0)::8>>
  end
  defp add_reliability_fields(header, %{reliability: 4} = frame) do
    <<header::binary, frame.reliable_index::24-little,
      (frame.sequenced_index || 0)::24-little,
      (frame.order_index || 0)::24-little, (frame.order_channel || 0)::8>>
  end
  defp add_reliability_fields(header, _), do: header

  defp add_split_fields(header, %{split: nil}), do: header
  defp add_split_fields(header, %{split: %{count: count, id: id, index: index}}) do
    <<header::binary, count::32, id::16, index::32>>
  end

  defp decode_reliable_index(r, rest) when r in [2, 3, 4, 6, 7] do
    <<idx::24-little, rest::binary>> = rest
    {idx, rest}
  end
  defp decode_reliable_index(_, rest), do: {nil, rest}

  defp decode_sequenced_index(r, rest) when r in [1, 4] do
    <<idx::24-little, rest::binary>> = rest
    {idx, rest}
  end
  defp decode_sequenced_index(_, rest), do: {nil, rest}

  defp decode_order_fields(r, rest) when r in [1, 3, 4, 7] do
    <<idx::24-little, channel::8, rest::binary>> = rest
    {idx, channel, rest}
  end
  defp decode_order_fields(_, rest), do: {nil, nil, rest}

  defp decode_split(1, <<count::32, id::16, index::32, rest::binary>>) do
    {%{count: count, id: id, index: index}, rest}
  end
  defp decode_split(_, rest), do: {nil, rest}
end
```

**Note:** The encode function has duplicate clauses above — this needs to be cleaned up during implementation. The correct approach is to handle each reliability type once, building up the binary progressively. The test will catch issues.

**Step 3: Run tests, commit**

```bash
mix test test/minecraft/bedrock/raknet/frame_test.exs
git add lib/minecraft/bedrock/raknet/frame.ex test/minecraft/bedrock/raknet/frame_test.exs
git commit -m "feat(bedrock): add RakNet frame (capsule) codec"
```

---

### Task 3: RakNet FrameSet + ACK/NAK Codec

Encode/decode FrameSet datagrams (sequence number + multiple frames) and ACK/NAK packets.

**Files:**
- Create: `lib/minecraft/bedrock/raknet/frame_set.ex`
- Create: `test/minecraft/bedrock/raknet/frame_set_test.exs`

**Step 1: Write failing tests**

```elixir
# test/minecraft/bedrock/raknet/frame_set_test.exs
defmodule Minecraft.Bedrock.RakNet.FrameSetTest do
  use ExUnit.Case, async: true
  alias Minecraft.Bedrock.RakNet.{FrameSet, Frame}

  describe "FrameSet" do
    test "encode and decode round-trip" do
      frames = [%Frame{reliability: 3, reliable_index: 0, order_index: 0, order_channel: 0, body: <<"hello">>}]
      encoded = FrameSet.encode(0, frames)
      assert {:frame_set, 0, decoded_frames} = FrameSet.decode(encoded)
      assert length(decoded_frames) == 1
      assert hd(decoded_frames).body == "hello"
    end
  end

  describe "ACK" do
    test "encode single ACK" do
      encoded = FrameSet.encode_ack([5])
      assert {:ack, [5]} = FrameSet.decode(encoded)
    end

    test "encode range ACK" do
      encoded = FrameSet.encode_ack([3, 4, 5])
      assert {:ack, sequences} = FrameSet.decode(encoded)
      assert 3 in sequences and 4 in sequences and 5 in sequences
    end
  end

  describe "NAK" do
    test "encode single NAK" do
      encoded = FrameSet.encode_nak([7])
      assert {:nak, [7]} = FrameSet.decode(encoded)
    end
  end
end
```

**Step 2: Implement FrameSet codec**

```elixir
# lib/minecraft/bedrock/raknet/frame_set.ex
defmodule Minecraft.Bedrock.RakNet.FrameSet do
  @moduledoc """
  RakNet FrameSet (datagram), ACK, and NAK codec.
  """
  alias Minecraft.Bedrock.RakNet.Frame

  # --- Decode ---

  def decode(<<0xC0, rest::binary>>), do: decode_ack_nak(:ack, rest)
  def decode(<<0xA0, rest::binary>>), do: decode_ack_nak(:nak, rest)

  def decode(<<flags::8, seq::24-little, rest::binary>>) when (flags &&& 0x80) == 0x80 do
    frames = decode_frames(rest, [])
    {:frame_set, seq, frames}
  end

  # --- Encode ---

  def encode(sequence_number, frames) do
    frame_data = Enum.map(frames, &Frame.encode/1) |> IO.iodata_to_binary()
    <<0x84, sequence_number::24-little, frame_data::binary>>
  end

  def encode_ack(sequences), do: encode_ack_nak(0xC0, sequences)
  def encode_nak(sequences), do: encode_ack_nak(0xA0, sequences)

  # --- Private ---

  defp decode_frames("", acc), do: Enum.reverse(acc)
  defp decode_frames(data, acc) do
    {frame, rest} = Frame.decode(data)
    decode_frames(rest, [frame | acc])
  end

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
    {type, Enum.sort(sequences)}
  end

  defp decode_records(rest, 0, acc), do: {List.flatten(Enum.reverse(acc)), rest}
  defp decode_records(<<1::8, seq::24-little, rest::binary>>, n, acc) do
    decode_records(rest, n - 1, [[seq] | acc])
  end
  defp decode_records(<<0::8, s::24-little, e::24-little, rest::binary>>, n, acc) do
    decode_records(rest, n - 1, [Enum.to_list(s..e) | acc])
  end

  defp to_ranges([]), do: []
  defp to_ranges([h | t]), do: to_ranges(t, h, h, [])
  defp to_ranges([], s, e, acc), do: Enum.reverse([{s, e} | acc])
  defp to_ranges([h | t], s, e, acc) when h == e + 1, do: to_ranges(t, s, h, acc)
  defp to_ranges([h | t], s, e, acc), do: to_ranges(t, h, h, [{s, e} | acc])
end
```

**Step 3: Run tests, commit**

```bash
mix test test/minecraft/bedrock/raknet/frame_set_test.exs
git commit -m "feat(bedrock): add RakNet FrameSet + ACK/NAK codec"
```

---

### Task 4: UDP Listener

GenServer that owns the UDP socket on port 19132, responds to Unconnected Pings (server list), and routes connection packets to Sessions.

**Files:**
- Create: `lib/minecraft/bedrock/listener.ex`
- Create: `test/minecraft/bedrock/listener_test.exs`

**Step 1: Write failing test**

```elixir
# test/minecraft/bedrock/listener_test.exs
defmodule Minecraft.Bedrock.ListenerTest do
  use ExUnit.Case, async: false

  @magic <<0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE,
           0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78>>

  test "responds to unconnected ping with pong" do
    # Send an Unconnected Ping to port 19132
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    ping = <<0x01, 12345::64, @magic::binary, 99::64>>
    :ok = :gen_udp.send(socket, ~c"127.0.0.1", 19132, ping)

    assert {:ok, {_addr, _port, pong}} = :gen_udp.recv(socket, 0, 2000)
    assert <<0x1C, 12345::64, _server_guid::64, @magic::binary, _rest::binary>> = pong
    :gen_udp.close(socket)
  end
end
```

**Step 2: Implement Listener**

```elixir
# lib/minecraft/bedrock/listener.ex
defmodule Minecraft.Bedrock.Listener do
  @moduledoc """
  UDP listener for Bedrock Edition on port 19132.
  Routes RakNet offline packets and forwards connection data to sessions.
  """
  use GenServer
  require Logger
  alias Minecraft.Bedrock.RakNet

  @default_port 19132

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def send_to(address, port, data) do
    GenServer.cast(__MODULE__, {:send, address, port, data})
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    {:ok, socket} = :gen_udp.open(port, [:binary, active: true, reuseaddr: true])
    server_guid = :rand.uniform(1 <<< 63)
    Logger.info("Bedrock listener started on UDP port #{port}")
    {:ok, %{socket: socket, port: port, server_guid: server_guid, sessions: %{}}}
  end

  @impl true
  def handle_info({:udp, _socket, address, port, data}, state) do
    state = handle_packet(address, port, data, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send, address, port, data}, state) do
    :gen_udp.send(state.socket, address, port, data)
    {:noreply, state}
  end

  defp handle_packet(address, port, data, state) do
    case RakNet.decode(data) do
      {:unconnected_ping, %{timestamp: ts}} ->
        motd = build_motd(state.server_guid)
        pong = RakNet.encode_unconnected_pong(ts, state.server_guid, motd)
        :gen_udp.send(state.socket, address, port, pong)
        state

      {:open_connection_request_1, %{protocol_version: 11, mtu_size: mtu}} ->
        reply = RakNet.encode_open_connection_reply_1(state.server_guid, mtu)
        :gen_udp.send(state.socket, address, port, reply)
        state

      {:open_connection_request_1, _} ->
        reply = RakNet.encode_incompatible_protocol(state.server_guid)
        :gen_udp.send(state.socket, address, port, reply)
        state

      {:open_connection_request_2, %{mtu_size: mtu, client_guid: client_guid}} ->
        reply = RakNet.encode_open_connection_reply_2(state.server_guid, address, port, mtu)
        :gen_udp.send(state.socket, address, port, reply)

        # Start a session for this client
        client_key = {address, port}
        {:ok, pid} = Minecraft.Bedrock.SessionSupervisor.start_session(
          client_key, state.server_guid, mtu, client_guid
        )
        sessions = Map.put(state.sessions, client_key, pid)
        %{state | sessions: sessions}

      _ ->
        # Route to existing session if any
        client_key = {address, port}
        case Map.get(state.sessions, client_key) do
          nil -> state
          pid -> send(pid, {:raknet_data, data}); state
        end
    end
  end

  defp build_motd(server_guid) do
    "MCPE;Elixir Minecraft;685;1.21.0;0;20;#{server_guid};Bedrock Level;Survival;1;19132;19133"
  end
end
```

**Step 3: Run test, commit**

```bash
mix test test/minecraft/bedrock/listener_test.exs
git commit -m "feat(bedrock): add UDP listener with ping/pong for server list"
```

---

### Task 5: Session GenServer — RakNet Connected Handshake

Per-client GenServer that manages RakNet state: sequence numbers, ACKs, split reassembly, and the connected handshake (ConnectionRequest → ConnectionRequestAccepted → NewIncomingConnection).

**Files:**
- Create: `lib/minecraft/bedrock/session.ex`
- Create: `lib/minecraft/bedrock/session_supervisor.ex`
- Test: integration via listener test

**This is the largest single task.** The session manages:
1. Incoming FrameSet decoding + ACK sending
2. Outgoing FrameSet encoding with sequence numbers
3. Split frame reassembly
4. Connected handshake (ConnectionRequest → ConnectionRequestAccepted)
5. Handoff to Bedrock protocol layer

```elixir
# lib/minecraft/bedrock/session_supervisor.ex
defmodule Minecraft.Bedrock.SessionSupervisor do
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def start_session(client_key, server_guid, mtu, client_guid) do
    DynamicSupervisor.start_child(__MODULE__, {
      Minecraft.Bedrock.Session,
      {client_key, server_guid, mtu, client_guid}
    })
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
```

```elixir
# lib/minecraft/bedrock/session.ex
defmodule Minecraft.Bedrock.Session do
  @moduledoc """
  Per-client GenServer managing a RakNet session + Bedrock protocol state.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Minecraft.Bedrock.RakNet
  alias Minecraft.Bedrock.RakNet.{Frame, FrameSet}

  defstruct [
    :client_key, :server_guid, :mtu, :client_guid,
    send_seq: 0,
    recv_seq: 0,
    reliable_index: 0,
    order_index: 0,
    splits: %{},
    bedrock_state: :connecting
  ]

  def start_link({client_key, server_guid, mtu, client_guid}) do
    GenServer.start_link(__MODULE__, {client_key, server_guid, mtu, client_guid})
  end

  @impl true
  def init({client_key, server_guid, mtu, client_guid}) do
    state = %__MODULE__{
      client_key: client_key,
      server_guid: server_guid,
      mtu: mtu,
      client_guid: client_guid
    }
    {:ok, state}
  end

  @impl true
  def handle_info({:raknet_data, data}, state) do
    state = handle_raknet(data, state)
    {:noreply, state}
  end

  # --- RakNet layer ---

  defp handle_raknet(data, state) do
    case FrameSet.decode(data) do
      {:frame_set, seq, frames} ->
        # Send ACK
        ack = FrameSet.encode_ack([seq])
        send_raw(state, ack)

        # Process each frame
        Enum.reduce(frames, state, &handle_frame/2)

      {:ack, _sequences} ->
        # We don't retransmit yet — just ignore
        state

      {:nak, _sequences} ->
        # TODO: retransmit
        state

      _ ->
        state
    end
  end

  defp handle_frame(%Frame{split: nil} = frame, state) do
    handle_payload(frame.body, state)
  end

  defp handle_frame(%Frame{split: %{id: id, count: count, index: index}} = frame, state) do
    parts = Map.get(state.splits, id, %{count: count, parts: %{}})
    parts = %{parts | parts: Map.put(parts.parts, index, frame.body)}

    if map_size(parts.parts) == count do
      # Reassemble
      body = Enum.map(0..(count - 1), fn i -> Map.fetch!(parts.parts, i) end) |> IO.iodata_to_binary()
      state = %{state | splits: Map.delete(state.splits, id)}
      handle_payload(body, state)
    else
      %{state | splits: Map.put(state.splits, id, parts)}
    end
  end

  # --- Connected handshake ---

  defp handle_payload(<<0x09, client_guid::64, timestamp::64-signed, 0x00>>, state) do
    Logger.info("Bedrock: ConnectionRequest from #{inspect(state.client_key)}")
    reply = encode_connection_request_accepted(state, timestamp)
    send_reliable(state, reply)
  end

  defp handle_payload(<<0x13, _rest::binary>>, state) do
    Logger.info("Bedrock: NewIncomingConnection — RakNet handshake complete")
    %{state | bedrock_state: :pre_login}
  end

  defp handle_payload(<<0x00, timestamp::64-signed>>, state) do
    # Connected Ping — respond with Connected Pong
    now = System.system_time(:millisecond)
    pong = <<0x03, timestamp::64-signed, now::64-signed>>
    send_reliable(state, pong)
  end

  defp handle_payload(<<0xFE, _rest::binary>> = data, state) do
    # Game packet batch — hand to Bedrock layer
    handle_bedrock_batch(data, state)
  end

  defp handle_payload(_data, state), do: state

  # --- Bedrock layer (placeholder for Tasks 6-9) ---

  defp handle_bedrock_batch(_data, state) do
    # Will be implemented in Tasks 6-9
    state
  end

  # --- Send helpers ---

  defp send_raw(state, data) do
    {address, port} = state.client_key
    Minecraft.Bedrock.Listener.send_to(address, port, data)
    state
  end

  defp send_reliable(state, payload) do
    frame = %Frame{
      reliability: 3,
      reliable_index: state.reliable_index,
      order_index: state.order_index,
      order_channel: 0,
      body: payload
    }
    frame_set = FrameSet.encode(state.send_seq, [frame])
    send_raw(state, frame_set)
    %{state | send_seq: state.send_seq + 1,
              reliable_index: state.reliable_index + 1,
              order_index: state.order_index + 1}
  end

  # --- Connection Request Accepted encoding ---

  defp encode_connection_request_accepted(state, client_timestamp) do
    {address, port} = state.client_key
    client_addr = RakNet.encode_address(address, port)
    system_index = <<0::16>>
    # 10 internal addresses (all zeros for IPv4)
    internal_addrs = :binary.copy(RakNet.encode_address({0, 0, 0, 0}, 0), 10)
    now = System.system_time(:millisecond)
    <<0x10, client_addr::binary, system_index::binary, internal_addrs::binary,
      client_timestamp::64-signed, now::64-signed>>
  end
end
```

**Step 3: Run tests, commit**

```bash
mix test
git add lib/minecraft/bedrock/session.ex lib/minecraft/bedrock/session_supervisor.ex
git commit -m "feat(bedrock): add Session GenServer with RakNet connected handshake"
```

---

### Task 6: Batch Codec (0xFE wrapper + compression)

The game packet layer wraps everything in a `0xFE` batch with zlib compression and varuint32-length-prefixed sub-packets.

**Files:**
- Create: `lib/minecraft/bedrock/codec.ex`
- Create: `test/minecraft/bedrock/codec_test.exs`

```elixir
# lib/minecraft/bedrock/codec.ex
defmodule Minecraft.Bedrock.Codec do
  @moduledoc """
  Bedrock batch packet codec: 0xFE header + compression + varuint length framing.
  """

  @spec encode_batch([binary], boolean) :: binary
  def encode_batch(packets, compress? \\ true) do
    inner =
      Enum.map(packets, fn pkt ->
        <<encode_varuint(byte_size(pkt))::binary, pkt::binary>>
      end)
      |> IO.iodata_to_binary()

    if compress? do
      compressed = :zlib.compress(inner)
      <<0xFE, compressed::binary>>
    else
      <<0xFE, 0xFF, inner::binary>>
    end
  end

  @spec decode_batch(binary) :: {:ok, [binary]} | {:error, term}
  def decode_batch(<<0xFE, rest::binary>>) do
    decompressed =
      try do
        :zlib.uncompress(rest)
      rescue
        _ -> rest  # May be uncompressed (0xFF prefix)
      end

    {:ok, decode_sub_packets(decompressed, [])}
  end
  def decode_batch(_), do: {:error, :not_a_batch}

  # --- Varuint encoding (same as Minecraft Protocol VarInt but unsigned) ---

  def encode_varuint(value) when value < 128, do: <<value::8>>
  def encode_varuint(value) do
    <<1::1, (value &&& 0x7F)::7, encode_varuint(value >>> 7)::binary>>
  end

  def decode_varuint(data), do: decode_varuint(data, 0, 0)
  defp decode_varuint(<<0::1, val::7, rest::binary>>, shift, acc) do
    {acc ||| (val <<< shift), rest}
  end
  defp decode_varuint(<<1::1, val::7, rest::binary>>, shift, acc) do
    decode_varuint(rest, shift + 7, acc ||| (val <<< shift))
  end

  # --- Game packet header (packet ID encoding) ---

  def encode_packet_header(packet_id) do
    encode_varuint(packet_id <<< 2)
  end

  def decode_packet_header(data) do
    {header, rest} = decode_varuint(data)
    {header >>> 2, rest}
  end

  # --- Private ---

  defp decode_sub_packets("", acc), do: Enum.reverse(acc)
  defp decode_sub_packets(data, acc) do
    {len, rest} = decode_varuint(data)
    <<packet::binary-size(len), rest::binary>> = rest
    decode_sub_packets(rest, [packet | acc])
  end
end
```

**Step 3: Run tests, commit**

---

### Task 7: Bedrock Game Packets (minimum set)

Encode/decode the minimum Bedrock packets needed for the login flow.

**Files:**
- Create: `lib/minecraft/bedrock/packet.ex`
- Create: `test/minecraft/bedrock/packet_test.exs`

This module handles encoding the server-side packets. Client packets are decoded just enough to extract needed fields.

Key packets to implement:
- `NetworkSettings` (ID 143 / 0x8F) — server → client
- `PlayStatus` (ID 2) — server → client
- `ResourcePacksInfo` (ID 6) — server → client
- `ResourcePackStack` (ID 7) — server → client
- `StartGame` (ID 11 / 0x0B) — server → client (large!)
- `ChunkRadiusUpdated` (ID 70 / 0x46) — server → client
- `NetworkChunkPublisherUpdate` (ID 121 / 0x79) — server → client
- `LevelChunk` (ID 58 / 0x3A) — server → client

Client-side (decode only):
- `RequestNetworkSettings` (ID 193 / 0xC1) — read protocol version
- `Login` (ID 1) — parse JWT chain for player name
- `ResourcePackClientResponse` (ID 8) — read status byte
- `RequestChunkRadius` (ID 69 / 0x45) — read radius
- `SetLocalPlayerAsInitialised` (ID 113 / 0x71) — no fields

This is a large file. The plan provides the module structure — exact binary formats should be referenced from wiki.bedrock.dev during implementation.

```bash
git commit -m "feat(bedrock): add minimum Bedrock game packet codec"
```

---

### Task 8: Login Flow in Session

Wire the Bedrock login state machine into Session: RequestNetworkSettings → NetworkSettings → Login → PlayStatus → ResourcePacks → StartGame → PlayerSpawn.

**Files:**
- Modify: `lib/minecraft/bedrock/session.ex` (add `handle_bedrock_batch` + state transitions)

The `bedrock_state` field transitions:
```
:pre_login → recv RequestNetworkSettings → send NetworkSettings → :logging_in
:logging_in → recv Login → send PlayStatus(0) → :resource_packs
:resource_packs → send ResourcePacksInfo → recv Response(3) → send ResourcePackStack → recv Response(4) → :starting
:starting → send StartGame + PlayStatus(3) → :spawning
:spawning → recv RequestChunkRadius → send ChunkRadiusUpdated + chunks → recv SetLocalPlayerAsInitialised → :playing
```

```bash
git commit -m "feat(bedrock): implement Bedrock login + spawn flow in session"
```

---

### Task 9: Flat World Chunk Generation

Generate and send minimal flat world chunks to the Bedrock client. Bedrock chunk format differs from Java — it uses SubChunk format v9 with runtime block palette.

**Files:**
- Create: `lib/minecraft/bedrock/chunk.ex`
- Modify: `lib/minecraft/bedrock/session.ex` (send chunks in :spawning state)

A flat world chunk (grass at y=64, dirt below, bedrock at y=0):
- SubChunk 0 (y=0-15): bedrock at y=0, stone y=1-15
- SubChunk 1 (y=16-31): stone
- SubChunk 2 (y=32-47): stone
- SubChunk 3 (y=48-63): dirt y=48-62, grass_block at y=63
- SubChunk 4 (y=64-79): air (or omit)

```bash
git commit -m "feat(bedrock): add flat world chunk generation for Bedrock clients"
```

---

### Task 10: Wire into Application Supervisor

Add `Minecraft.Bedrock.Listener` and `Minecraft.Bedrock.SessionSupervisor` to the application's supervision tree.

**Files:**
- Modify: `lib/minecraft/application.ex`

```elixir
# Add to children list:
Minecraft.Bedrock.SessionSupervisor,
Minecraft.Bedrock.Listener
```

```bash
git commit -m "feat(bedrock): wire Bedrock listener into application supervisor"
```

---

### Task 11: Deploy to Fly.io with Bedrock port

**Files:**
- Modify: `fly.toml` (add UDP port 19132)

Add a second service block:

```toml
[[services]]
  internal_port = 19132
  protocol = "udp"

  [[services.ports]]
    port = 19132
```

```bash
flyctl deploy -a minecraft-devsnorte
```

Players can then add the server in Minecraft Bedrock (mobile):
- **Server Address:** `minecraft-devsnorte.fly.dev`
- **Port:** `19132`

---

## Summary

| Task | Description | Size | Dependencies |
|------|-------------|------|-------------|
| 1 | RakNet offline codec | S | none |
| 2 | Frame (capsule) codec | M | none |
| 3 | FrameSet + ACK/NAK codec | M | Task 2 |
| 4 | UDP Listener | M | Task 1 |
| 5 | Session + RakNet handshake | L | Tasks 1-4 |
| 6 | Batch codec (0xFE + zlib) | S | none |
| 7 | Bedrock game packets | L | none |
| 8 | Login flow in Session | L | Tasks 5-7 |
| 9 | Flat world chunks | M | Task 8 |
| 10 | Wire into supervisor | S | Task 9 |
| 11 | Fly.io deploy | S | Task 10 |
