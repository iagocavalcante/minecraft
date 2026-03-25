# Minecraft Server (Elixir)

Minecraft 1.12.2 (Protocol 340) server implementation in Elixir with C NIFs for terrain generation.

**Stack**: Elixir ~> 1.6, Ranch 2.1, HTTPoison, Poison, C99 NIFs
**Structure**: OTP supervision tree with per-connection GenServers, gen_statem for game sequencing, C NIFs for chunk generation (Perlin noise + Voronoi biomes)

For detailed architecture, see [docs/CODEBASE_MAP.md](docs/CODEBASE_MAP.md).
