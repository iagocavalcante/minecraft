defmodule Minecraft.Bedrock.Items do
  @moduledoc """
  The vanilla Bedrock item table for protocol 1001.

  Backed by `priv/required_item_list.json` (from pmmp/BedrockData, generated
  from the vanilla server for exactly this protocol). The client needs the
  full table in ItemRegistry to identify items by their numeric runtime IDs;
  mobile clients crash when items they encounter are missing from it.

  The parsed table is cached in `:persistent_term` on first use — it is
  static data read by every joining session.
  """

  @persistent_key {__MODULE__, :items}

  @typedoc "One item table entry."
  @type entry :: %{name: String.t(), runtime_id: integer, version: integer}

  @doc """
  All vanilla items, as entries for the ItemRegistry packet.
  """
  @spec all() :: [entry]
  def all do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        items = load()
        :persistent_term.put(@persistent_key, items)
        items

      items ->
        items
    end
  end

  @doc """
  The numeric runtime ID for an item name, e.g. `"minecraft:stone"`.
  """
  @spec runtime_id(String.t()) :: {:ok, integer} | :error
  def runtime_id(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil -> :error
      %{runtime_id: id} -> {:ok, id}
    end
  end

  defp load do
    path = Path.join(:code.priv_dir(:minecraft), "required_item_list.json")

    path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn {name, %{"runtime_id" => runtime_id, "version" => version}} ->
      %{name: name, runtime_id: runtime_id, version: version}
    end)
    |> Enum.sort_by(& &1.name)
  end
end
