defmodule Mom.Audit do
  @moduledoc false

  require Logger

  @spec emit(atom(), map()) :: :ok
  def emit(event, metadata) when is_atom(event) and is_map(metadata) do
    :telemetry.execute([:mom, :audit, event], %{count: 1}, metadata)

    payload =
      metadata
      |> Map.put(:event, Atom.to_string(event))
      |> Jason.encode!()

    Logger.info("mom: audit #{payload}")
    :ok
  end
end
