defmodule Mom.Status do
  @moduledoc """
  Health of each watched target, kept in ETS.

  Per target: connection (`connected`, `connected_since`, `down_since`),
  project info (`:mom_info` of the app), the last event, and the errors of the
  last 24 hours (newest first, at most 200 per target).

  The state is derived when read:

    * `unknown` - not yet connected (no attempt finished yet),
    * `down` - not connected,
    * `warn` - connected, with errors in the last hour,
    * `ok` - connected, no error in the last hour.

  Times are Unix milliseconds. Every write function takes an optional `now`
  so tests can control the clock. The table is public: each target's watcher
  is the only writer of its own row.
  """

  use GenServer

  @table :mom_status
  @max_errors 200
  @error_window_ms 24 * 60 * 60 * 1000
  @warn_window_ms 60 * 60 * 1000
  @message_max 160

  @type error :: %{at: integer(), kind: String.t(), message: String.t(), fingerprint: String.t()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @doc "Adds a target in state `unknown` if it is not known yet."
  @spec register(String.t()) :: :ok
  def register(name) do
    with_table(fn ->
      :ets.insert_new(@table, {name, new_row(name)})
      :ok
    end)
  end

  @doc "Marks a target connected and stores its project info."
  @spec connected(String.t(), map(), integer()) :: :ok
  def connected(name, info, now \\ now_ms()) do
    update(name, fn row ->
      %{
        row
        | connected: true,
          attempted: true,
          connected_since: now,
          down_since: nil,
          info: info,
          note: nil
      }
    end)
  end

  @doc "Marks a target down. `down_since` keeps the time of the first failure."
  @spec down(String.t(), String.t() | nil, integer()) :: :ok
  def down(name, note \\ nil, now \\ now_ms()) do
    update(name, fn row ->
      %{
        row
        | connected: false,
          connected_since: nil,
          attempted: true,
          down_since: row.down_since || now,
          note: note || row.note
      }
    end)
  end

  @doc "Records any event from the target (liveness)."
  @spec event(String.t(), String.t(), integer()) :: :ok
  def event(name, kind, now \\ now_ms()) do
    update(name, fn row -> %{row | last_event: %{at: now, kind: kind}} end)
  end

  @doc "Records an error. Keeps the last 24 h, at most #{@max_errors}."
  @spec error(String.t(), String.t(), String.t(), integer()) :: :ok
  def error(name, kind, message, now \\ now_ms()) do
    message = short_message(message)

    entry = %{
      at: now,
      kind: kind,
      message: message,
      fingerprint: fingerprint(kind, message)
    }

    update(name, fn row ->
      errors =
        [entry | row.errors]
        |> Enum.take_while(&(&1.at > now - @error_window_ms))
        |> Enum.take(@max_errors)

      %{row | errors: errors, last_event: %{at: now, kind: kind}}
    end)
  end

  @doc "All targets, sorted by name, each with its derived state."
  @spec all(integer()) :: [map()]
  def all(now \\ now_ms()) do
    with_table(
      fn ->
        @table
        |> :ets.tab2list()
        |> Enum.map(fn {_name, row} -> view(row, now) end)
        |> Enum.sort_by(& &1.name)
      end,
      []
    )
  end

  @doc "One target with its derived state, or nil."
  @spec get(String.t(), integer()) :: map() | nil
  def get(name, now \\ now_ms()) do
    with_table(
      fn ->
        case :ets.lookup(@table, name) do
          [{^name, row}] -> view(row, now)
          [] -> nil
        end
      end,
      nil
    )
  end

  @doc "Removes all targets (tests)."
  def reset do
    with_table(fn ->
      :ets.delete_all_objects(@table)
      :ok
    end)
  end

  @doc "First line of a message, whitespace collapsed, cut to #{@message_max} characters."
  @spec short_message(term()) :: String.t()
  def short_message(message) when is_binary(message) do
    message
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, @message_max)
  end

  def short_message(other), do: other |> inspect(limit: 20) |> short_message()

  @doc """
  Stable id of an error: SHA-256 of the kind and the message with numbers,
  pids, references and hex ids replaced, first 12 hex characters.
  """
  @spec fingerprint(String.t(), String.t()) :: String.t()
  def fingerprint(kind, message) do
    normalized =
      message
      |> String.replace(~r/#(PID|Reference|Port)<[^>]*>/, "#\\1")
      |> String.replace(~r/\b0x[0-9a-fA-F]+\b/, "H")
      |> String.replace(~r/\b[0-9a-fA-F]{8,}\b/, "H")
      |> String.replace(~r/\d+/, "N")

    :crypto.hash(:sha256, kind <> "\0" <> normalized)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  @spec now_ms() :: integer()
  def now_ms, do: System.system_time(:millisecond)

  defp new_row(name) do
    %{
      name: name,
      connected: false,
      attempted: false,
      connected_since: nil,
      down_since: nil,
      info: %{},
      note: nil,
      last_event: nil,
      errors: []
    }
  end

  defp update(name, fun) do
    with_table(fn ->
      row =
        case :ets.lookup(@table, name) do
          [{^name, row}] -> row
          [] -> new_row(name)
        end

      :ets.insert(@table, {name, fun.(row)})
      :ok
    end)
  end

  defp view(row, now) do
    errors = Enum.filter(row.errors, &(&1.at > now - @error_window_ms))
    errors_1h = Enum.count(errors, &(&1.at > now - @warn_window_ms))

    state =
      cond do
        row.connected and errors_1h > 0 -> :warn
        row.connected -> :ok
        row.attempted -> :down
        true -> :unknown
      end

    row
    |> Map.drop([:attempted])
    |> Map.merge(%{
      state: state,
      errors: errors,
      errors_1h: errors_1h,
      last_error: List.first(errors)
    })
  end

  defp with_table(fun, default \\ :ok) do
    if :ets.whereis(@table) == :undefined, do: default, else: fun.()
  end
end
