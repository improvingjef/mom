defmodule Mom.Audit do
  @moduledoc false

  alias Mom.Alerting
  alias Mom.Security

  require Logger

  @spec emit(atom(), map()) :: :ok
  def emit(event, metadata) when is_atom(event) and is_map(metadata) do
    sanitized_metadata =
      metadata
      |> Security.sanitize(redact_keys())
      |> apply_pii_handling_policy()

    :telemetry.execute([:mom, :audit, event], %{count: 1}, sanitized_metadata)
    _ = Alerting.observe(event, sanitized_metadata)

    payload =
      sanitized_metadata
      |> Map.put(:event, Atom.to_string(event))

    write_soc2_evidence(payload)

    encoded_payload =
      payload
      |> Jason.encode!()

    Logger.info("mom: audit #{encoded_payload}")
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

  defp apply_pii_handling_policy(metadata) do
    case pii_handling_policy() do
      :redact -> metadata
      :drop -> drop_sensitive_keys(metadata, MapSet.new(Enum.map(redact_keys(), &String.downcase/1)))
    end
  end

  defp pii_handling_policy do
    case Application.get_env(:mom, :pii_handling_policy) do
      :drop -> :drop
      "drop" -> :drop
      _other -> :redact
    end
  end

  defp drop_sensitive_keys(map, keys) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key_str = key_to_string(key) |> String.downcase()

      if MapSet.member?(keys, key_str) do
        acc
      else
        Map.put(acc, key, drop_sensitive_keys(value, keys))
      end
    end)
  end

  defp drop_sensitive_keys(list, keys) when is_list(list),
    do: Enum.map(list, &drop_sensitive_keys(&1, keys))

  defp drop_sensitive_keys(tuple, keys) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&drop_sensitive_keys(&1, keys))
    |> List.to_tuple()
  end

  defp drop_sensitive_keys(value, _keys), do: value

  defp write_soc2_evidence(payload) do
    case soc2_evidence_path() do
      nil ->
        :ok

      path ->
        persisted = Map.put(payload, :recorded_at_unix, DateTime.utc_now() |> DateTime.to_unix())
        retention_seconds = audit_retention_days() * 86_400
        cutoff = persisted.recorded_at_unix - retention_seconds

        records =
          read_existing_evidence(path)
          |> Enum.filter(&(Map.get(&1, "recorded_at_unix", 0) >= cutoff))
          |> Kernel.++([stringify_keys(persisted)])

        encoded = Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
        tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(tmp_path, encoded),
             :ok <- File.rename(tmp_path, path) do
          :ok
        else
          {:error, reason} ->
            _ = File.rm(tmp_path)
            Logger.warning("mom: failed to write soc2 evidence #{inspect(reason)}")
            :ok
        end
    end
  end

  defp read_existing_evidence(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{} = record} -> [record]
            _other -> []
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("mom: failed to read soc2 evidence #{inspect(reason)}")
        []
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key_to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&stringify_keys/1)
  defp stringify_keys(value), do: value

  defp soc2_evidence_path do
    case Application.get_env(:mom, :soc2_evidence_path) do
      path when is_binary(path) ->
        trimmed = String.trim(path)
        if trimmed == "", do: nil, else: trimmed

      _other ->
        nil
    end
  end

  defp audit_retention_days do
    case Application.get_env(:mom, :audit_retention_days) do
      days when is_integer(days) and days > 0 ->
        days

      days when is_binary(days) ->
        case Integer.parse(days) do
          {parsed, _rest} when parsed > 0 -> parsed
          _other -> 30
        end

      _other ->
        30
    end
  end

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)
end
