defmodule Mom.SpendLimiter do
  @moduledoc false

  @table :mom_spend_limiter
  @default_window_ms 3_600_000

  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end

    :ok
  end

  @spec allow_spend?(String.t(), atom(), non_neg_integer(), pos_integer() | nil, pos_integer()) ::
          boolean()
  def allow_spend?(repo, category, amount, cap, window_ms \\ @default_window_ms)

  def allow_spend?(_repo, _category, _amount, nil, _window_ms), do: true

  def allow_spend?(repo, category, amount, cap, window_ms)
      when is_binary(repo) and is_atom(category) and is_integer(amount) and amount >= 0 and
             is_integer(cap) and cap > 0 and is_integer(window_ms) and window_ms > 0 do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    key = {:spend, repo, category}

    entries =
      case :ets.lookup(@table, key) do
        [{^key, list}] when is_list(list) -> list
        _ -> []
      end

    recent =
      Enum.filter(entries, fn {ts, _value} ->
        is_integer(ts) and now - ts <= window_ms
      end)

    spent =
      Enum.reduce(recent, 0, fn {_ts, value}, acc ->
        if is_integer(value) and value >= 0 do
          acc + value
        else
          acc
        end
      end)

    if spent + amount <= cap do
      if amount > 0 do
        :ets.insert(@table, {key, [{now, amount} | recent]})
      else
        :ets.insert(@table, {key, recent})
      end

      true
    else
      false
    end
  end

  def allow_spend?(_repo, _category, _amount, _cap, _window_ms), do: false
end
