defmodule Mom.Security do
  @moduledoc false

  @spec sanitize(term(), [String.t()]) :: term()
  def sanitize(value, redact_keys) do
    do_sanitize(value, MapSet.new(Enum.map(redact_keys, &String.downcase/1)))
  rescue
    _ -> value
  end

  @spec signature(term()) :: String.t()
  def signature(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end

  @spec egress_allowed?(String.t(), [String.t()]) :: boolean()
  def egress_allowed?(url, allowed_hosts) when is_binary(url) and is_list(allowed_hosts) do
    host = url_host(url)

    is_binary(host) and
      Enum.map(allowed_hosts, &String.downcase/1)
      |> Enum.member?(String.downcase(host))
  end

  @spec url_host(String.t()) :: String.t() | nil
  def url_host(url) when is_binary(url) do
    URI.parse(url).host
  end

  def url_host(_url), do: nil

  defp do_sanitize(%{__struct__: _} = struct, redact_keys) do
    struct
    |> Map.from_struct()
    |> do_sanitize(redact_keys)
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
