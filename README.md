# Minecraft

A Minecraft server implementation in Elixir supporting both **Java Edition** (1.12.2, Protocol 340) and **Bedrock Edition** (1.26.0, Protocol 924).

> **Fork of [thecodeboss/minecraft](https://github.com/thecodeboss/minecraft)** — original by Michael Oliver. This fork adds Bedrock Edition support, upgrades dependencies to modern Elixir/OTP, and deploys to Fly.io.

Until this reaches version 1.0, please do not consider it ready for running real Minecraft servers (unless you're adventurous).

You can view [the documentation on Hex](https://hexdocs.pm/minecraft/).

![Screenshot](./docs/screenshot.png)

## Minecraft Protocol

The Minecraft Protocol is documented on [wiki.vg](http://wiki.vg/Protocol). The current goal is to support version (1.12.2, protocol 340).

## To-do

The following list of to-do items should be enough to be able to play on the server, at least to the most basic extent.

### General

- [x] World Generation
- [x] World in-memory storage
- [x] World persistence on disk (basic — Erlang term storage)
- [ ] Core server logic (this is a catch-all)

### Handshake Packets

- [x] Client: Handshake

### Status Packets

- [x] Client: Request
- [x] Server: Response
- [x] Client: Ping
- [x] Server: Pong

### Login Packets

- [x] Client: Login Start
- [x] Server: Encryption Request
- [x] Client: Encryption Response
- [ ] _(optional)_ Server: Set Compression
- [x] Server: Login Success
- [x] Server: Disconnect

### Play Packets

- [x] Server: Join Game
- [x] Server: Spawn Position
- [x] Server: Time Update
- [x] Server: Player Abilities
- [x] Client: Plugin Message
- [x] Client: Client Settings
- [x] Server: Player Position and Look
- [x] Client: Teleport Confirm (with ID validation)
- [x] Client: Player Position and Look
- [x] Client: Client Status
- [x] Server: Window Items
- [x] Server: Chunk Data
- [x] Client: Player
- [x] Client: Player Position
- [x] Client: Player Look
- [x] Client: Chat Message
- [x] Server: Chat Message
- [x] Server: Keep Alive (with 30s timeout kick)
- [x] Client: Keep Alive
