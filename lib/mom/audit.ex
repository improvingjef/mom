defmodule Mom.Audit do
  @moduledoc false

  alias Mom.Security

  require Logger

  @spec emit(atom(), map()) :: :ok
  def emit(event, metadata) when is_atom(event) and is_map(metadata) do
    sanitized_metadata = Security.sanitize(metadata, redact_keys())

    :telemetry.execute([:mom, :audit, event], %{count: 1}, sanitized_metadata)

    payload =
      sanitized_metadata
      |> Map.put(:event, Atom.to_string(event))
      |> Jason.encode!()

    Logger.info("mom: audit #{payload}")
    :ok
  end

  defp redact_keys do
    case Application.get_env(:mom, :redact_keys) do
      nil ->
        ["password", "passwd", "secret", "token", "api_key", "apikey", "authorization", "cookie"]

      keys when is_list(keys) ->
        Enum.map(keys, &to_string/1)

      keys when is_binary(keys) ->
        keys
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        ["password", "passwd", "secret", "token", "api_key", "apikey", "authorization", "cookie"]
    end
  end
end
