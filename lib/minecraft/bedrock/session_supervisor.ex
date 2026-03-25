defmodule Minecraft.Bedrock.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for Bedrock client sessions.
  Each connecting Bedrock client gets its own Session process.
  """
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def start_session(client_key, server_guid, mtu, client_guid) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Minecraft.Bedrock.Session, {client_key, server_guid, mtu, client_guid}}
    )
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
