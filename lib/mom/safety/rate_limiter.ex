defmodule Mom.RateLimiter do
  @moduledoc false

  @table :mom_rate_limiter

  def ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end

    :ok
  end

  @spec allow?(term(), pos_integer(), pos_integer()) :: boolean()
  def allow?(bucket, limit, window_ms) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    timestamps =
      case :ets.lookup(@table, bucket) do
        [{^bucket, list}] -> list
        _ -> []
      end

    recent = Enum.filter(timestamps, fn ts -> now - ts <= window_ms end)

    if length(recent) < limit do
      :ets.insert(@table, {bucket, [now | recent]})
      true
    else
      false
    end
  end

  @spec allow_issue_signature?(String.t(), pos_integer()) :: boolean()
  def allow_issue_signature?(signature, window_ms) do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    key = {:issue_signature, signature}

    case :ets.lookup(@table, key) do
      [{^key, ts}] when now - ts <= window_ms ->
        false

      _ ->
        :ets.insert(@table, {key, now})
        true
    end
  end
end
