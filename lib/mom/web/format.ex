defmodule Mom.Web.Format do
  @moduledoc """
  Text and JSON forms of `Mom.Status` views. Text is short on purpose: an
  agent reads it from a loop. Times are UTC.

      school  ok    0.1.0 4db6647  errors 1h: 0
      latte   warn  0.1.0 9f2c1aa  errors 1h: 3  last 13:52 Postgrex timeout
      revivehub down                connected: no since 12:10
  """

  @last_message_max 60

  @doc "One line per target."
  @spec status_text([map()]) :: String.t()
  def status_text([]), do: "no targets\n"

  def status_text(targets) do
    name_w = targets |> Enum.map(&String.length(&1.name)) |> Enum.max()
    state_w = targets |> Enum.map(&String.length(Atom.to_string(&1.state))) |> Enum.max()
    version_w = targets |> Enum.map(&String.length(version(&1))) |> Enum.max()

    targets
    |> Enum.map(fn t ->
      head =
        String.pad_trailing(t.name, name_w) <>
          "  " <> String.pad_trailing(Atom.to_string(t.state), state_w)

      version_col = if version_w > 0, do: [String.pad_trailing(version(t), version_w)], else: []
      Enum.join([head | version_col] ++ [tail(t)], "  ")
    end)
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "A header line for one target, then its errors, newest first."
  @spec target_text(map()) :: String.t()
  def target_text(t) do
    info =
      t.info
      |> Map.take(["repo", "env", "release", "commit"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.sort()
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

    head =
      [t.name, Atom.to_string(t.state), info, connection(t), "errors 24h: #{length(t.errors)}"]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("  ")

    lines =
      Enum.map(t.errors, fn e ->
        "#{datetime(e.at)}  #{e.kind}  #{e.fingerprint}  #{e.message}"
      end)

    Enum.join([head | lines], "\n") <> "\n"
  end

  @doc "JSON-ready map of one target; errors only when `errors?`."
  @spec json(map(), boolean()) :: map()
  def json(t, errors?) do
    base = %{
      name: t.name,
      state: t.state,
      connected: t.connected,
      connected_since: iso(t.connected_since),
      down_since: iso(t.down_since),
      note: t.note,
      info: t.info,
      last_event: t.last_event && %{at: iso(t.last_event.at), kind: t.last_event.kind},
      errors_1h: t.errors_1h,
      errors_24h: length(t.errors),
      last_error: t.last_error && error_json(t.last_error)
    }

    if errors?, do: Map.put(base, :errors, Enum.map(t.errors, &error_json/1)), else: base
  end

  defp error_json(e) do
    %{at: iso(e.at), kind: e.kind, message: e.message, fingerprint: e.fingerprint}
  end

  defp version(%{state: state}) when state in [:down, :unknown], do: ""

  defp version(%{info: info}) do
    release = info["release"] || "?"
    commit = if is_binary(info["commit"]), do: String.slice(info["commit"], 0, 7), else: "?"
    "#{release} #{commit}"
  end

  defp tail(%{state: :down} = t) do
    errors = if t.errors_1h > 0, do: "  errors 1h: #{t.errors_1h}", else: ""
    note = if t.note, do: "  #{t.note}", else: ""
    "connected: no since #{hhmm(t.down_since)}" <> errors <> note
  end

  defp tail(%{state: :unknown}), do: "connected: no"

  defp tail(t) do
    last =
      case t.last_error do
        nil -> ""
        e -> "  last #{hhmm(e.at)} #{String.slice(e.message, 0, @last_message_max)}"
      end

    "errors 1h: #{t.errors_1h}" <> last
  end

  defp connection(%{connected: true, connected_since: since}),
    do: "connected since #{datetime(since)}"

  defp connection(%{down_since: nil}), do: "connected: no"
  defp connection(%{down_since: since}), do: "connected: no since #{datetime(since)}"

  defp hhmm(nil), do: "?"
  defp hhmm(ms), do: ms |> to_dt() |> Calendar.strftime("%H:%M")

  defp datetime(nil), do: "?"
  defp datetime(ms), do: ms |> to_dt() |> Calendar.strftime("%Y-%m-%d %H:%M:%SZ")

  defp iso(nil), do: nil
  defp iso(ms), do: ms |> to_dt() |> DateTime.to_iso8601()

  defp to_dt(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)
end
