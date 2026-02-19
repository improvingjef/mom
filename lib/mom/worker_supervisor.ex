defmodule Mom.WorkerSupervisor do
  @moduledoc false

  use DynamicSupervisor

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
