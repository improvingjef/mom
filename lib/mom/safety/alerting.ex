defmodule Mom.Alerting do
  @moduledoc false

  require Logger

  @table :mom_alerting
  @default_window_ms 60_000
  @default_pr_spike_threshold 5
  @default_auth_failure_threshold 3
  @default_disallowed_repo_threshold 1

  @spec observe(atom(), map()) :: :ok
  def observe(event, metadata) when is_atom(event) and is_map(metadata) do
    case signal(event, metadata) do
      {:ok, signal} ->
        maybe_emit_alert(signal)

      :ignore ->
        :ok
    end
  end

  def observe(_event, _metadata), do: :ok

  defp signal(:github_pr_created, metadata) do
    repo = Map.get(metadata, :repo)
    actor_id = actor_id(metadata)

    if is_binary(repo) and repo != "" do
      {:ok,
       %{
         alert_type: :pr_spike,
         signal_key: {:pr_spike, repo, actor_id},
         threshold: read_threshold(:alert_pr_spike_threshold, @default_pr_spike_threshold),
         window_ms: read_window_ms(),
         metadata: %{repo: repo, actor_id: actor_id}
       }}
    else
      :ignore
    end
  end

  defp signal(event, metadata)
       when event in [:github_issue_failed, :github_pr_failed, :github_merge_failed] do
    reason = Map.get(metadata, :reason)
    repo = Map.get(metadata, :repo)
    actor_id = actor_id(metadata)

    if is_binary(repo) and repo != "" and auth_failure_reason?(reason) do
      {:ok,
       %{
         alert_type: :auth_failure_spike,
         signal_key: {:auth_failure_spike, repo, actor_id},
         threshold:
           read_threshold(:alert_auth_failure_threshold, @default_auth_failure_threshold),
         window_ms: read_window_ms(),
         metadata: %{repo: repo, actor_id: actor_id, reason: reason}
       }}
    else
      :ignore
    end
  end

  defp signal(:github_repo_disallowed, metadata) do
    repo = Map.get(metadata, :repo)
    actor_id = actor_id(metadata)

    if is_binary(repo) and repo != "" do
      {:ok,
       %{
         alert_type: :disallowed_repo_target,
         signal_key: {:disallowed_repo_target, repo, actor_id},
         threshold:
           read_threshold(:alert_disallowed_repo_threshold, @default_disallowed_repo_threshold),
         window_ms: read_window_ms(),
         metadata: %{
           repo: repo,
           actor_id: actor_id,
           allowed_repos: Map.get(metadata, :allowed_repos, [])
         }
       }}
    else
      :ignore
    end
  end

  defp signal(_event, _metadata), do: :ignore

  defp maybe_emit_alert(%{
         alert_type: alert_type,
         signal_key: signal_key,
         threshold: threshold,
         window_ms: window_ms,
         metadata: metadata
       }) do
    now_ms = System.system_time(:millisecond)

    case bump_counter(signal_key, now_ms, threshold, window_ms) do
      {:triggered, observed_count} ->
        alert_metadata =
          metadata
          |> Map.put(:alert_type, alert_type)
          |> Map.put(:threshold, threshold)
          |> Map.put(:observed_count, observed_count)
          |> Map.put(:window_ms, window_ms)

        :telemetry.execute([:mom, :alert, :unusual_activity], %{count: 1}, alert_metadata)

        payload =
          alert_metadata
          |> Map.put(:event, "unusual_activity")
          |> Jason.encode!()

        Logger.warning("mom: alert #{payload}")
        :ok

      :ok ->
        :ok
    end
  end

  defp bump_counter(signal_key, now_ms, threshold, window_ms) do
    table = ensure_table()

    {observed_count, alert_already_emitted, new_alert_emitted} =
      case :ets.lookup(table, signal_key) do
        [{^signal_key, window_started_at, count, emitted?}]
        when is_integer(window_started_at) and now_ms - window_started_at < window_ms ->
          next_count = count + 1
          next_emitted = emitted? or next_count >= threshold
          :ets.insert(table, {signal_key, window_started_at, next_count, next_emitted})
          {next_count, emitted?, next_emitted}

        _ ->
          emitted? = threshold <= 1
          :ets.insert(table, {signal_key, now_ms, 1, emitted?})
          {1, false, emitted?}
      end

    cond do
      observed_count >= threshold and not alert_already_emitted and new_alert_emitted ->
        {:triggered, observed_count}

      true ->
        :ok
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      tid ->
        tid
    end
  end

  defp actor_id(metadata) do
    case Map.get(metadata, :actor_id) do
      nil -> "unknown"
      "" -> "unknown"
      actor when is_binary(actor) -> actor
      actor -> to_string(actor)
    end
  end

  defp auth_failure_reason?(reason) when is_binary(reason) do
    String.contains?(String.downcase(reason), [
      "{:http_error, 401",
      "{:http_error, 403",
      "unauthorized",
      "forbidden",
      "auth"
    ])
  end

  defp auth_failure_reason?(_), do: false

  defp read_window_ms do
    case Application.get_env(:mom, :alert_window_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_window_ms
    end
  end

  defp read_threshold(key, default) do
    case Application.get_env(:mom, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
