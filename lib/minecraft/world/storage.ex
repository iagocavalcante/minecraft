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
