defmodule Minecraft.World do
  @moduledoc """
  Stores Minecraft world data.
  """
  use GenServer
  alias Minecraft.NIF
  require Logger

  @type world_opts :: [{:seed, integer}]

  @doc """
  Starts the Minecraft World, which will initialize the spawn area.
  """
  @spec start_link(world_opts) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a specific chunk, loading it if necessary.

  The chunk will be already encoded into chunk sections for the client.
  """
  @spec get_chunk(integer, integer) :: Minecraft.Chunk.t()
  def get_chunk(x, z) do
    # :infinity — on-demand chunk generation can exceed the default 5s timeout
    # when many chunks are requested back-to-back during join.
    GenServer.call(__MODULE__, {:get_chunk, x, z}, :infinity)
  end

  @doc """
  Sets a block at world coordinates. `type` is a Java 1.12 global block type
  (`id <<< 4 ||| meta`); the owning chunk is generated first if needed.
  """
  @spec set_block(integer, 0..255, integer, 0..0xFFFF) :: :ok | :error
  def set_block(x, y, z, type) do
    GenServer.call(__MODULE__, {:set_block, x, y, z, type}, :infinity)
  end

  #
  # Callbacks
  #

  @impl true
  def init(opts) do
    seed = Keyword.get(opts, :seed, 1230)
    :ok = NIF.set_random_seed(seed)
    init_spawn_area()
    {:ok, %{seed: seed, chunks: %{}}}
  end

  @impl true
  def handle_call({:get_chunk, x, z}, _from, state) do
    {chunk, state} = ensure_chunk(state, x, z)
    {:reply, chunk, state}
  end

  def handle_call({:set_block, x, y, z, type}, _from, state)
      when y in 0..255 and type in 0..0xFFFF do
    {chunk, state} = ensure_chunk(state, Integer.floor_div(x, 16), Integer.floor_div(z, 16))
    result = NIF.set_block(chunk.resource, Integer.mod(x, 16), y, Integer.mod(z, 16), type)
    {:reply, result, state}
  end

  def handle_call({:set_block, _x, _y, _z, _type}, _from, state) do
    {:reply, :error, state}
  end

  @impl true
  def handle_info({:load_chunk, x, z}, state) do
    {_chunk, state} = ensure_chunk(state, x, z)
    {:noreply, state}
  end

  #
  # Helpers
  #

  defp ensure_chunk(%{chunks: chunks} = state, x, z) do
    case get_in(chunks, [x, z]) do
      nil ->
        {:ok, resource} = NIF.generate_chunk(x, z)
        chunk = %Minecraft.Chunk{resource: resource}
        chunks = Map.put_new(chunks, x, %{})
        chunks = put_in(chunks, [x, z], chunk)
        {chunk, %{state | chunks: chunks}}

      chunk ->
        {chunk, state}
    end
  end

  defp init_spawn_area() do
    for x <- -20..20 do
      for z <- -20..20 do
        send(self(), {:load_chunk, x, z})
      end
    end
  end
end
