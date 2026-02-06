defmodule Mom.Security do
  @moduledoc false

  @spec sanitize(term(), [String.t()]) :: term()
  def sanitize(value, redact_keys) do
    do_sanitize(value, MapSet.new(Enum.map(redact_keys, &String.downcase/1)))
  end

  @spec signature(term()) :: String.t()
  def signature(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end

  defp do_sanitize(map, redact_keys) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      key_str = key_to_string(k)

      if MapSet.member?(redact_keys, String.downcase(key_str)) do
        {k, "[REDACTED]"}
      else
        {k, do_sanitize(v, redact_keys)}
      end
    end)
    |> Map.new()
  end

  defp do_sanitize(list, redact_keys) when is_list(list) do
    Enum.map(list, &do_sanitize(&1, redact_keys))
  end

  defp do_sanitize(tuple, redact_keys) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&do_sanitize(&1, redact_keys))
    |> List.to_tuple()
  end

  defp do_sanitize(value, _redact_keys), do: value

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)
end
