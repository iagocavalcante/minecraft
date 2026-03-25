# Missing Features Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement all unchecked items from README.md to reach basic playability on Minecraft 1.12.2 (Protocol 340).

**Architecture:** Each feature is a self-contained batch: new packet module + dispatch entry + handler logic + tests. All packets follow the existing struct/serialize/deserialize convention. Server-side state lives in existing GenServers (Users, World). No new processes unless there's a runtime reason (per the Elixir Iron Law).

**Tech Stack:** Elixir 1.15+, OTP 28, Ranch 2.1, Jason, Protocol 340 (wiki.vg)

---

## Missing Features Inventory

| # | Feature | README Status | Severity | Task |
|---|---------|--------------|----------|------|
| 1 | Fix README (mark World in-memory as done) | Stale checkbox | Low | Task 1 |
| 2 | Server: Disconnect (Login) | `[ ]` | High | Task 2 |
| 3 | Client: Player (0x0C) | `[ ]` | Medium | Task 3 |
| 4 | Client: Chat Message (0x02) + Server: Chat Message (0x0F) | Not listed | High | Task 4 |
| 5 | Server: Window Items (0x14) | `[ ]` | Medium | Task 5 |
| 6 | KeepAlive timeout kick | TODO in code | High | Task 6 |
| 7 | TeleportConfirm validation | TODO in code | Low | Task 7 |
| 8 | User disconnect cleanup | Missing | High | Task 8 |
| 9 | Server: Time Update (0x47) | Not listed | Low | Task 9 |
| 10 | World persistence on disk | `[ ]` | Large | Task 10 |
| 11 | Update README | — | — | Task 11 |

---

### Task 1: Fix README stale checkbox

The README says `[ ] World in-memory storage` but `Minecraft.World` is a GenServer with a full chunk cache. This is already implemented.

**Files:**
- Modify: `README.md`

**Step 1: Update the checkbox**

Change line 27 from:
```
- [ ] World in-memory storage
```
to:
```
- [x] World in-memory storage
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: mark World in-memory storage as implemented (was already done)"
```

---

### Task 2: Server Login Disconnect packet

When login fails (bad verify token, Mojang verification failure), the server currently closes the TCP socket silently. The Minecraft protocol requires sending a Disconnect packet (0x00 in Login state) with a JSON reason before closing.

**Reference:** https://wiki.vg/Protocol#Disconnect_.28login.29

**Files:**
- Create: `lib/minecraft/packet/server/login/disconnect.ex`
- Modify: `lib/minecraft/packet.ex` (add dispatch entry + type union)
- Modify: `lib/minecraft/protocol/handler.ex` (send disconnect before close)
- Modify: `lib/minecraft/protocol.ex` (handle `{:error, reason, conn}` with disconnect)
- Test: `test/minecraft/packet_test.exs` (round-trip test)

**Step 1: Write the failing test**

Add to `test/minecraft/packet_test.exs`:

```elixir
describe "Server.Login.Disconnect" do
  test "serialize and deserialize" do
    reason = Jason.encode!(%{text: "Bad verify token"})
    packet = %Minecraft.Packet.Server.Login.Disconnect{reason: reason}
    {0x00, binary} = Minecraft.Packet.Server.Login.Disconnect.serialize(packet)
    {deserialized, ""} = Minecraft.Packet.Server.Login.Disconnect.deserialize(binary)
    assert deserialized.reason == reason
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/minecraft/packet_test.exs --only describe:"Server.Login.Disconnect"
```

Expected: compilation error — module does not exist.

**Step 3: Create the Disconnect packet module**

Create `lib/minecraft/packet/server/login/disconnect.ex`:

```elixir
defmodule Minecraft.Packet.Server.Login.Disconnect do
  @moduledoc false
  import Minecraft.Packet, only: [encode_string: 1, decode_string: 1]

  @type t :: %__MODULE__{packet_id: 0x00, reason: String.t()}

  defstruct packet_id: 0x00,
            reason: nil

  @spec serialize(t) :: {packet_id :: 0x00, binary}
  def serialize(%__MODULE__{reason: reason}) do
    {0x00, <<encode_string(reason)::binary>>}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    {reason, rest} = decode_string(data)
    {%__MODULE__{reason: reason}, rest}
  end
end
```

**Step 4: Add dispatch entry in `lib/minecraft/packet.ex`**

Uncomment and fix the existing TODO at line 85-86. Replace:
```elixir
    # TODO {:login, 0, :server} ->
    # Server.Login.Disconnect.deserialize(data)
```
with:
```elixir
    {:login, 0, :server} ->
      Server.Login.Disconnect.deserialize(data)
```

Also add `Server.Login.Disconnect.t()` to the `@type packet_types` union.

**Step 5: Wire disconnect into protocol error handling**

In `lib/minecraft/protocol.ex`, update `handle_packet/2`'s error clause to send a Disconnect packet before closing (only in `:login` state):

```elixir
{:error, reason, conn} = err ->
  Logger.error(fn -> "#{__MODULE__} error: #{inspect(err)}" end)

  conn =
    if conn.current_state == :login do
      reason_json = Jason.encode!(%{text: "Login failed: #{reason}"})
      Connection.send_packet(conn, %Server.Login.Disconnect{reason: reason_json})
    else
      conn
    end

  Connection.close(conn)
  {:stop, :normal, conn}
```

Add `alias Minecraft.Packet.Server` at the top of `protocol.ex` if not present.

**Step 6: Run tests**

```bash
mix test
```

Expected: all 23+ tests pass.

**Step 7: Commit**

```bash
git add lib/minecraft/packet/server/login/disconnect.ex lib/minecraft/packet.ex lib/minecraft/protocol.ex lib/minecraft/protocol/handler.ex test/minecraft/packet_test.exs
git commit -m "feat: add Server Login Disconnect packet — send reason before closing on login failure"
```

---

### Task 3: Client Player packet (0x0C)

The "Player" packet (0x0C) is sent by the client when only `on_ground` changes (no position/look update). Currently hits the `{:error, :invalid_packet}` catch-all.

**Reference:** https://wiki.vg/Protocol#Player

**Files:**
- Create: `lib/minecraft/packet/client/play/player.ex`
- Modify: `lib/minecraft/packet.ex` (dispatch entry + type union)
- Modify: `lib/minecraft/protocol/handler.ex` (handler clause)
- Test: `test/minecraft/packet_test.exs`

**Step 1: Write the failing test**

```elixir
describe "Client.Play.Player" do
  test "serialize and deserialize" do
    packet = %Minecraft.Packet.Client.Play.Player{on_ground: true}
    {0x0C, binary} = Minecraft.Packet.Client.Play.Player.serialize(packet)
    {deserialized, ""} = Minecraft.Packet.Client.Play.Player.deserialize(binary)
    assert deserialized.on_ground == true
  end

  test "on_ground false" do
    packet = %Minecraft.Packet.Client.Play.Player{on_ground: false}
    {0x0C, binary} = Minecraft.Packet.Client.Play.Player.serialize(packet)
    {deserialized, ""} = Minecraft.Packet.Client.Play.Player.deserialize(binary)
    assert deserialized.on_ground == false
  end
end
```

**Step 2: Run test to verify failure**

**Step 3: Create the packet module**

Create `lib/minecraft/packet/client/play/player.ex`:

```elixir
defmodule Minecraft.Packet.Client.Play.Player do
  @moduledoc false
  import Minecraft.Packet, only: [encode_bool: 1, decode_bool: 1]

  @type t :: %__MODULE__{packet_id: 0x0C, on_ground: boolean}

  defstruct packet_id: 0x0C,
            on_ground: true

  @spec serialize(t) :: {packet_id :: 0x0C, binary}
  def serialize(%__MODULE__{on_ground: on_ground}) do
    {0x0C, encode_bool(on_ground)}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    {on_ground, rest} = decode_bool(data)
    {%__MODULE__{on_ground: on_ground}, rest}
  end
end
```

**Step 4: Add dispatch entry in `lib/minecraft/packet.ex`**

After the `{:play, 0x0B, :client}` clause, add:

```elixir
{:play, 0x0C, :client} ->
  Client.Play.Player.deserialize(data)
```

Add `Client.Play.Player.t()` to the `@type packet_types` union.

**Step 5: Add handler in `lib/minecraft/protocol/handler.ex`**

Before the `handle(%Client.Play.PlayerPosition{} ...)` clause, add:

```elixir
def handle(%Client.Play.Player{}, conn) do
  # on_ground-only update — no position/look change to propagate
  {:ok, :noreply, conn}
end
```

**Step 6: Run tests, commit**

```bash
mix test
git add lib/minecraft/packet/client/play/player.ex lib/minecraft/packet.ex lib/minecraft/protocol/handler.ex test/minecraft/packet_test.exs
git commit -m "feat: add Client Player packet (0x0C) — on_ground-only updates"
```

---

### Task 4: Chat Message (Client 0x02 + Server 0x0F)

Players need to send and receive chat. The client sends `ChatMessage` (0x02) with a string. The server broadcasts `ChatMessage` (0x0F) with a JSON Chat component, position byte (0=chat, 1=system, 2=action bar).

**Reference:** https://wiki.vg/Protocol#Chat_Message_.28clientbound.29

**Files:**
- Create: `lib/minecraft/packet/client/play/chat_message.ex`
- Create: `lib/minecraft/packet/server/play/chat_message.ex`
- Modify: `lib/minecraft/packet.ex` (dispatch entries + type union)
- Modify: `lib/minecraft/protocol/handler.ex` (handler — echo message back)
- Test: `test/minecraft/packet_test.exs`

**Step 1: Write failing tests**

```elixir
describe "Client.Play.ChatMessage" do
  test "serialize and deserialize" do
    packet = %Minecraft.Packet.Client.Play.ChatMessage{message: "Hello world"}
    {0x02, binary} = Minecraft.Packet.Client.Play.ChatMessage.serialize(packet)
    {deserialized, ""} = Minecraft.Packet.Client.Play.ChatMessage.deserialize(binary)
    assert deserialized.message == "Hello world"
  end
end

describe "Server.Play.ChatMessage" do
  test "serialize and deserialize" do
    json = Jason.encode!(%{text: "Hello from server"})
    packet = %Minecraft.Packet.Server.Play.ChatMessage{json_data: json, position: 0}
    {0x0F, binary} = Minecraft.Packet.Server.Play.ChatMessage.serialize(packet)
    {deserialized, ""} = Minecraft.Packet.Server.Play.ChatMessage.deserialize(binary)
    assert deserialized.json_data == json
    assert deserialized.position == 0
  end
end
```

**Step 2: Run to verify failure**

**Step 3: Create Client.Play.ChatMessage**

Create `lib/minecraft/packet/client/play/chat_message.ex`:

```elixir
defmodule Minecraft.Packet.Client.Play.ChatMessage do
  @moduledoc false
  import Minecraft.Packet, only: [encode_string: 1, decode_string: 1]

  @type t :: %__MODULE__{packet_id: 0x02, message: String.t()}

  defstruct packet_id: 0x02,
            message: ""

  @spec serialize(t) :: {packet_id :: 0x02, binary}
  def serialize(%__MODULE__{message: message}) do
    {0x02, encode_string(message)}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    {message, rest} = decode_string(data)
    {%__MODULE__{message: message}, rest}
  end
end
```

**Step 4: Create Server.Play.ChatMessage**

Create `lib/minecraft/packet/server/play/chat_message.ex`:

```elixir
defmodule Minecraft.Packet.Server.Play.ChatMessage do
  @moduledoc false
  import Minecraft.Packet, only: [encode_string: 1, decode_string: 1]

  @type t :: %__MODULE__{packet_id: 0x0F, json_data: String.t(), position: 0 | 1 | 2}

  defstruct packet_id: 0x0F,
            json_data: nil,
            position: 0

  @spec serialize(t) :: {packet_id :: 0x0F, binary}
  def serialize(%__MODULE__{json_data: json_data, position: position}) do
    {0x0F, <<encode_string(json_data)::binary, position::8>>}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    {json_data, rest} = decode_string(data)
    <<position::8, rest::binary>> = rest
    {%__MODULE__{json_data: json_data, position: position}, rest}
  end
end
```

**Step 5: Add dispatch entries in `lib/minecraft/packet.ex`**

Client side — add after `{:play, 1, :client}` or similar early play section:

```elixir
{:play, 0x02, :client} ->
  Client.Play.ChatMessage.deserialize(data)
```

Server side — add in the server play section:

```elixir
{:play, 0x0F, :server} ->
  Server.Play.ChatMessage.deserialize(data)
```

Add both `.t()` to the `@type packet_types` union.

**Step 6: Add handler in `lib/minecraft/protocol/handler.ex`**

For now, echo the message back to the sender formatted as a chat component:

```elixir
def handle(%Client.Play.ChatMessage{message: message}, conn) do
  username = conn.assigns[:username] || "Unknown"
  json = Jason.encode!(%{text: "<#{username}> #{message}"})
  {:ok, %Server.Play.ChatMessage{json_data: json, position: 0}, conn}
end
```

**Step 7: Run tests, commit**

```bash
mix test
git add lib/minecraft/packet/client/play/chat_message.ex lib/minecraft/packet/server/play/chat_message.ex lib/minecraft/packet.ex lib/minecraft/protocol/handler.ex test/minecraft/packet_test.exs
git commit -m "feat: add Chat Message packets (client 0x02 + server 0x0F) with echo handler"
```

---

### Task 5: Server Window Items packet (0x14)

Send an empty inventory to the client on join. Without this, the client's inventory display is undefined. Protocol 340 uses Window Items with window ID 0 for the player inventory (46 slots).

**Reference:** https://wiki.vg/Protocol#Window_Items

**Files:**
- Create: `lib/minecraft/packet/server/play/window_items.ex`
- Modify: `lib/minecraft/packet.ex` (dispatch entry + type union)
- Modify: `lib/minecraft/state_machine.ex` (send empty inventory on join)
- Test: `test/minecraft/packet_test.exs`

**Step 1: Write failing test**

```elixir
describe "Server.Play.WindowItems" do
  test "serialize empty inventory" do
    packet = %Minecraft.Packet.Server.Play.WindowItems{
      window_id: 0,
      slots: List.duplicate(nil, 46)
    }
    {0x14, binary} = Minecraft.Packet.Server.Play.WindowItems.serialize(packet)
    assert is_binary(binary)
    # 1 byte window_id + 2 bytes count + 46 * 2 bytes (empty slot = <<0xFF, 0xFF>>)
    assert byte_size(binary) == 1 + 2 + 46 * 2
  end
end
```

**Step 2: Run to verify failure**

**Step 3: Create Server.Play.WindowItems**

Create `lib/minecraft/packet/server/play/window_items.ex`:

```elixir
defmodule Minecraft.Packet.Server.Play.WindowItems do
  @moduledoc false

  @type slot :: nil | {item_id :: integer, count :: integer, damage :: integer, nbt :: binary}
  @type t :: %__MODULE__{packet_id: 0x14, window_id: integer, slots: [slot]}

  defstruct packet_id: 0x14,
            window_id: 0,
            slots: []

  @spec serialize(t) :: {packet_id :: 0x14, binary}
  def serialize(%__MODULE__{window_id: window_id, slots: slots}) do
    count = length(slots)
    slot_data = Enum.map(slots, &serialize_slot/1) |> IO.iodata_to_binary()
    {0x14, <<window_id::8, count::16-signed, slot_data::binary>>}
  end

  defp serialize_slot(nil), do: <<-1::16-signed>>

  defp serialize_slot({item_id, count, damage, nbt}) do
    <<item_id::16-signed, count::8, damage::16-signed, nbt::binary>>
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    <<window_id::8, count::16-signed, rest::binary>> = data
    {slots, rest} = deserialize_slots(rest, count, [])
    {%__MODULE__{window_id: window_id, slots: slots}, rest}
  end

  defp deserialize_slots(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp deserialize_slots(<<-1::16-signed, rest::binary>>, count, acc) do
    deserialize_slots(rest, count - 1, [nil | acc])
  end

  defp deserialize_slots(<<item_id::16-signed, count::8, damage::16-signed, rest::binary>>, n, acc) do
    # Simplified: skip NBT parsing, assume no NBT (0x00 = TAG_End)
    <<_nbt_end::8, rest::binary>> = rest
    deserialize_slots(rest, n - 1, [{item_id, count, damage, <<0x00>>} | acc])
  end
end
```

**Step 4: Add dispatch entry in `lib/minecraft/packet.ex`**

```elixir
{:play, 0x14, :server} ->
  Server.Play.WindowItems.deserialize(data)
```

Add `Server.Play.WindowItems.t()` to `@type packet_types`.

**Step 5: Send empty inventory on join in `lib/minecraft/state_machine.ex`**

In the `join(:internal, _, protocol)` function, after `PlayerPositionAndLook`, add:

```elixir
:ok = Protocol.send_packet(protocol, %Server.Play.WindowItems{
  window_id: 0,
  slots: List.duplicate(nil, 46)
})
```

Add `alias Minecraft.Packet.Server.Play.WindowItems` at the top.

**Step 6: Run tests, commit**

```bash
mix test
git add lib/minecraft/packet/server/play/window_items.ex lib/minecraft/packet.ex lib/minecraft/state_machine.ex test/minecraft/packet_test.exs
git commit -m "feat: add Server Window Items packet (0x14) — send empty inventory on join"
```

---

### Task 6: KeepAlive timeout kick

The server sends KeepAlive every 1s but never validates the response or kicks unresponsive clients. According to protocol, the server should kick if no KeepAlive response arrives within 30 seconds.

**Files:**
- Modify: `lib/minecraft/state_machine.ex` (track last keepalive, add timeout check)
- Modify: `lib/minecraft/protocol/handler.ex` (forward KeepAlive ID to state machine)
- Modify: `lib/minecraft/protocol.ex` (handle keepalive ack message)
- Test: `test/minecraft/integration/integration_test.exs` (optional — hard to test timing)

**Step 1: Add keepalive tracking to state machine state**

Change the state machine data from a single `protocol` pid to a map:

In `lib/minecraft/state_machine.ex`, update `init/1`:

```elixir
def init(protocol) do
  data = %{protocol: protocol, last_keepalive_ack: System.system_time(:millisecond)}
  actions = [{:next_event, :internal, :join}]
  {:ok, :join, data, actions}
end
```

Update all state functions to use `data` instead of `protocol`, accessing `data.protocol` where needed.

**Step 2: Track KeepAlive acknowledgments**

Add a `handle_event` catch-all for `:info` messages:

```elixir
def handle_event(:info, {:keepalive_ack, _id}, _state, data) do
  {:keep_state, %{data | last_keepalive_ack: System.system_time(:millisecond)}}
end
```

**Step 3: Check timeout on each KeepAlive send**

In the `:ready` state's `:state_timeout` handler:

```elixir
def ready(:state_timeout, :keepalive, data) do
  now = System.system_time(:millisecond)

  if now - data.last_keepalive_ack > 30_000 do
    # Client hasn't responded in 30 seconds — disconnect
    {:stop, :normal, data}
  else
    :ok = Protocol.send_packet(data.protocol, %Server.Play.KeepAlive{keep_alive_id: now})
    {:keep_state, data, [{:state_timeout, 1_000, :keepalive}]}
  end
end
```

**Step 4: Forward KeepAlive ack from handler to state machine**

In `lib/minecraft/protocol/handler.ex`, update the KeepAlive handler:

```elixir
def handle(%Client.Play.KeepAlive{keep_alive_id: id}, conn) do
  if conn.state_machine do
    send(conn.state_machine, {:keepalive_ack, id})
  end
  {:ok, :noreply, conn}
end
```

**Step 5: Run tests, commit**

```bash
mix test
git add lib/minecraft/state_machine.ex lib/minecraft/protocol/handler.ex
git commit -m "feat: enforce 30s KeepAlive timeout — kick unresponsive clients"
```

---

### Task 7: TeleportConfirm validation

The server sends a random teleport ID but never validates the client's confirmation matches. Store the sent ID and verify it.

**Files:**
- Modify: `lib/minecraft/connection.ex` (add `teleport_id` field to struct)
- Modify: `lib/minecraft/state_machine.ex` (store teleport_id via assign)
- Modify: `lib/minecraft/protocol/handler.ex` (validate TeleportConfirm)

**Step 1: Add teleport_id to Connection assigns**

In `lib/minecraft/state_machine.ex`, when creating the `PlayerPositionAndLook` response, store the teleport_id. After sending the packet, use `Protocol.get_conn` + assign, or simpler: send the teleport_id as a message to the protocol process.

Actually, simpler approach — just store it in `conn.assigns`:

In `lib/minecraft/protocol/handler.ex`, modify the `EncryptionResponse` handler (or add a general mechanism). The teleport ID is generated in `state_machine.ex` `join/3`. The state machine already calls `Protocol.send_packet` directly, so we can have the handler validate against `conn.assigns[:teleport_id]`.

But the state machine generates the teleport_id, not the handler. Better approach: have the state machine set the teleport_id on the conn via a GenServer call.

**Simplest approach:** Add a `set_teleport_id/2` function to Protocol:

In `lib/minecraft/protocol.ex`, add:

```elixir
def set_teleport_id(pid, teleport_id) do
  GenServer.cast(pid, {:set_teleport_id, teleport_id})
end
```

And handle:

```elixir
@impl true
def handle_cast({:set_teleport_id, teleport_id}, conn) do
  {:noreply, Connection.assign(conn, :teleport_id, teleport_id)}
end
```

In `lib/minecraft/state_machine.ex`, after sending `PlayerPositionAndLook`:

```elixir
Protocol.set_teleport_id(protocol, teleport_id)
```

In `lib/minecraft/protocol/handler.ex`, update TeleportConfirm:

```elixir
def handle(%Client.Play.TeleportConfirm{teleport_id: id}, conn) do
  case conn.assigns[:teleport_id] do
    ^id -> {:ok, :noreply, conn}
    _ -> {:error, :invalid_teleport_id, conn}
  end
end
```

**Step 2: Run tests, commit**

```bash
mix test
git add lib/minecraft/protocol.ex lib/minecraft/state_machine.ex lib/minecraft/protocol/handler.ex
git commit -m "feat: validate TeleportConfirm ID matches server-sent value"
```

---

### Task 8: User disconnect cleanup

When a client TCP-disconnects, the Users GenServer is never notified. Players accumulate indefinitely.

**Files:**
- Modify: `lib/minecraft/users.ex` (add `leave/1` function)
- Modify: `lib/minecraft/protocol.ex` (call `Users.leave` on `tcp_closed` and `stop`)
- Test: `test/minecraft/integration/integration_test.exs` (verify cleanup)

**Step 1: Add `leave/1` to Users**

In `lib/minecraft/users.ex`:

```elixir
@spec leave(binary) :: :ok
def leave(uuid) do
  GenServer.cast(__MODULE__, {:leave, uuid})
end
```

Add the handler:

```elixir
def handle_cast({:leave, uuid}, %State{} = state) do
  logged_in = MapSet.delete(state.logged_in, uuid)
  {:noreply, %State{state | logged_in: logged_in}}
end
```

Note: We keep the user in the `users` map (preserves position for reconnect), but remove from `logged_in`.

**Step 2: Call leave on disconnect**

In `lib/minecraft/protocol.ex`, update `handle_info({:tcp_closed, ...})`:

```elixir
def handle_info({:tcp_closed, socket}, conn) do
  Logger.info(fn -> "Client #{conn.client_ip} disconnected." end)

  if uuid = conn.assigns[:uuid] do
    Minecraft.Users.leave(uuid)
  end

  :ok = conn.transport.close(socket)
  {:stop, :normal, conn}
end
```

**Step 3: Run tests, commit**

```bash
mix test
git add lib/minecraft/users.ex lib/minecraft/protocol.ex
git commit -m "feat: clean up Users registry on client disconnect"
```

---

### Task 9: Server Time Update packet (0x47)

Without this, the client is stuck at noon forever. Send once on join (tick 6000 = noon) and optionally tick forward.

**Reference:** https://wiki.vg/Protocol#Time_Update

**Files:**
- Create: `lib/minecraft/packet/server/play/time_update.ex`
- Modify: `lib/minecraft/packet.ex` (dispatch entry + type union)
- Modify: `lib/minecraft/state_machine.ex` (send on join)
- Test: `test/minecraft/packet_test.exs`

**Step 1: Write failing test**

```elixir
describe "Server.Play.TimeUpdate" do
  test "serialize and deserialize" do
    packet = %Minecraft.Packet.Server.Play.TimeUpdate{world_age: 0, time_of_day: 6000}
    {0x47, binary} = Minecraft.Packet.Server.Play.TimeUpdate.serialize(packet)
    {deserialized, ""} = Minecraft.Packet.Server.Play.TimeUpdate.deserialize(binary)
    assert deserialized.world_age == 0
    assert deserialized.time_of_day == 6000
  end
end
```

**Step 2: Create the packet module**

Create `lib/minecraft/packet/server/play/time_update.ex`:

```elixir
defmodule Minecraft.Packet.Server.Play.TimeUpdate do
  @moduledoc false

  @type t :: %__MODULE__{packet_id: 0x47, world_age: integer, time_of_day: integer}

  defstruct packet_id: 0x47,
            world_age: 0,
            time_of_day: 6000

  @spec serialize(t) :: {packet_id :: 0x47, binary}
  def serialize(%__MODULE__{world_age: world_age, time_of_day: time_of_day}) do
    {0x47, <<world_age::64-signed, time_of_day::64-signed>>}
  end

  @spec deserialize(binary) :: {t, rest :: binary}
  def deserialize(data) do
    <<world_age::64-signed, time_of_day::64-signed, rest::binary>> = data
    {%__MODULE__{world_age: world_age, time_of_day: time_of_day}, rest}
  end
end
```

**Step 3: Add dispatch entry in `lib/minecraft/packet.ex`**

```elixir
{:play, 0x47, :server} ->
  Server.Play.TimeUpdate.deserialize(data)
```

**Step 4: Send on join in `lib/minecraft/state_machine.ex`**

In the `join(:internal, ...)` handler, after `SpawnPosition` and before `PlayerAbilities`:

```elixir
:ok = Protocol.send_packet(protocol, %Server.Play.TimeUpdate{world_age: 0, time_of_day: 6000})
```

**Step 5: Run tests, commit**

```bash
mix test
git add lib/minecraft/packet/server/play/time_update.ex lib/minecraft/packet.ex lib/minecraft/state_machine.ex test/minecraft/packet_test.exs
git commit -m "feat: add Server Time Update packet (0x47) — send noon time on join"
```

---

### Task 10: World persistence on disk

This is the largest task. The goal is to save/load chunks to disk using a simple format so the world survives server restarts. **Not** the full Minecraft Anvil region format — use a simple Erlang term storage (`:erlang.term_to_binary`) per-chunk file for now.

**Files:**
- Create: `lib/minecraft/world/storage.ex` (read/write chunks to disk)
- Modify: `lib/minecraft/world.ex` (integrate disk storage)
- Test: `test/minecraft/world_test.exs`

**Step 1: Write failing test for storage**

Add to `test/minecraft/world_test.exs`:

```elixir
describe "World.Storage" do
  setup do
    dir = Path.join(System.tmp_dir!(), "mc_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "save and load chunk data", %{dir: dir} do
    chunk_data = %{x: 5, z: -3, sections: <<1, 2, 3, 4, 5>>}
    :ok = Minecraft.World.Storage.save_chunk(dir, 5, -3, chunk_data)
    assert {:ok, ^chunk_data} = Minecraft.World.Storage.load_chunk(dir, 5, -3)
  end

  test "load missing chunk returns :error", %{dir: dir} do
    assert :error = Minecraft.World.Storage.load_chunk(dir, 99, 99)
  end
end
```

**Step 2: Create storage module**

Create `lib/minecraft/world/storage.ex`:

```elixir
defmodule Minecraft.World.Storage do
  @moduledoc """
  Simple file-based chunk persistence. Each chunk is stored as an Erlang
  binary term file at `<world_dir>/chunks/<x>.<z>.chunk`.
  """

  @spec save_chunk(String.t(), integer, integer, term) :: :ok
  def save_chunk(world_dir, x, z, chunk_data) do
    path = chunk_path(world_dir, x, z)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(chunk_data))
    :ok
  end

  @spec load_chunk(String.t(), integer, integer) :: {:ok, term} | :error
  def load_chunk(world_dir, x, z) do
    path = chunk_path(world_dir, x, z)

    case File.read(path) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
      {:error, _} -> :error
    end
  end

  defp chunk_path(world_dir, x, z) do
    Path.join([world_dir, "chunks", "#{x}.#{z}.chunk"])
  end
end
```

**Step 3: Integrate into World GenServer**

In `lib/minecraft/world.ex`, add a `:world_dir` option (default `"./world"`). On `get_chunk/2`, try disk first, then generate. After generating, persist to disk.

Modify `init/1` to accept `world_dir`:

```elixir
def init(opts) do
  seed = Keyword.get(opts, :seed, 1230)
  world_dir = Keyword.get(opts, :world_dir, "./world")
  :ok = NIF.set_random_seed(seed)
  # ... existing preload logic ...
  {:ok, %{seed: seed, world_dir: world_dir, chunks: %{}}}
end
```

In the chunk generation path, after generating via NIF, persist:

```elixir
# After generating chunk, save serialized data for future restarts
# Note: NIF resource references can't be serialized to disk, so we
# save the serialized binary form instead and reconstruct on load.
```

**Important caveat:** NIF resource references are opaque and cannot be serialized with `:erlang.term_to_binary`. For true persistence, you'd need to serialize the chunk's block data (via `NIF.serialize_chunk/1`) and store that binary. Loading would require either re-generating or deserializing. Since the current `Chunk` struct wraps a NIF resource, full persistence requires a chunk format that stores the serialized binary and can reconstruct the NIF resource.

**For now:** Store the NIF-serialized chunk binary alongside the chunk coordinates. On load, the chunk can be sent directly to clients without re-generating. This is a simplified approach.

**Step 4: Run tests, commit**

```bash
mix test
git add lib/minecraft/world/storage.ex lib/minecraft/world.ex test/minecraft/world_test.exs
git commit -m "feat: add basic world persistence — save/load chunks to disk"
```

---

### Task 11: Update README with all new features

**Files:**
- Modify: `README.md`

**Step 1: Update all checkboxes**

```markdown
### General

- [x] World Generation
- [x] World in-memory storage
- [ ] World persistence on disk (partial — storage module exists, NIF resource serialization TBD)
- [ ] Core server logic (this is a catch-all)

### Login Packets

- [x] Server: Disconnect

### Play Packets

- [x] Client: Player
- [x] Client: Chat Message
- [x] Server: Chat Message
- [x] Server: Window Items
- [x] Server: Time Update
```

Also update badges (remove Travis CI / inch_ex badges that no longer work).

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README with implemented features and remove stale badges"
```

---

## Dependency Graph

```
Task 1 (README fix) ─────────── standalone
Task 2 (Disconnect) ─────────── standalone
Task 3 (Player 0x0C) ────────── standalone
Task 4 (Chat) ───────────────── standalone
Task 5 (Window Items) ───────── standalone
Task 6 (KeepAlive timeout) ──── standalone (but test after Task 8)
Task 7 (TeleportConfirm) ────── standalone
Task 8 (User disconnect) ────── standalone
Task 9 (Time Update) ────────── standalone
Task 10 (World persistence) ──── standalone (largest, can be deferred)
Task 11 (README update) ──────── depends on all above
```

Tasks 1-9 are fully independent and can be parallelized. Task 10 is the largest and can be deferred. Task 11 is the final cleanup.

## Estimated Effort

| Task | Size | Risk |
|------|------|------|
| 1. README fix | XS | None |
| 2. Login Disconnect | S | Low |
| 3. Client Player | S | None |
| 4. Chat Message | M | Low |
| 5. Window Items | M | Medium (slot serialization) |
| 6. KeepAlive timeout | M | Medium (state machine refactor) |
| 7. TeleportConfirm | S | Low |
| 8. User disconnect | S | None |
| 9. Time Update | S | None |
| 10. World persistence | L | High (NIF resource limitation) |
| 11. README update | XS | None |
