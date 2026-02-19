defmodule Mom.Observability do
  @moduledoc false

  use GenServer

  require Logger

  @handler_events [
    [:mom, :pipeline, :enqueued],
    [:mom, :pipeline, :dropped],
    [:mom, :pipeline, :started],
    [:mom, :pipeline, :completed],
    [:mom, :pipeline, :failed]
  ]

  @default_export_interval_ms 5_000
  @default_queue_depth_threshold 150
  @default_drop_rate_threshold 0.05
  @default_failure_rate_threshold 0.1
  @default_latency_p95_ms_threshold 15_000
  @max_duration_samples 512

  @type t :: %{
          enqueued_total: non_neg_integer(),
          dropped_total: non_neg_integer(),
          started_total: non_neg_integer(),
          completed_total: non_neg_integer(),
          failed_total: non_neg_integer(),
          queue_depth: non_neg_integer(),
          queue_depth_max: non_neg_integer(),
          active_workers: non_neg_integer(),
          active_workers_max: non_neg_integer(),
          drop_rate: float(),
          failure_rate: float(),
          latency_p95_ms: float()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec snapshot(pid() | atom()) :: t()
  def snapshot(server) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    export_path = Keyword.fetch!(opts, :export_path)
    export_interval_ms = Keyword.get(opts, :export_interval_ms, @default_export_interval_ms)

    thresholds = %{
      queue_depth: Keyword.get(opts, :queue_depth_threshold, @default_queue_depth_threshold),
      drop_rate: Keyword.get(opts, :drop_rate_threshold, @default_drop_rate_threshold),
      failure_rate: Keyword.get(opts, :failure_rate_threshold, @default_failure_rate_threshold),
      latency_p95_ms:
        Keyword.get(opts, :latency_p95_ms_threshold, @default_latency_p95_ms_threshold)
    }

    handler_id = "mom-observability-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        @handler_events,
        fn event, measurements, metadata, pid ->
          send(pid, {:pipeline_telemetry, event, measurements, metadata})
        end,
        parent
      )

    state =
      initial_state(export_path, export_interval_ms, handler_id, thresholds)
      |> export_metrics()

    schedule_export(export_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  @impl true
  def handle_info({:pipeline_telemetry, event, measurements, metadata}, state) do
    next_state =
      state
      |> apply_event(event, measurements, metadata)
      |> evaluate_slos()
      |> export_metrics()

    {:noreply, next_state}
  end

  def handle_info(:export_metrics, state) do
    schedule_export(state.export_interval_ms)
    {:noreply, export_metrics(state)}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  defp initial_state(export_path, export_interval_ms, handler_id, thresholds) do
    %{
      export_path: export_path,
      export_interval_ms: export_interval_ms,
      handler_id: handler_id,
      thresholds: thresholds,
      breaches: %{},
      enqueued_total: 0,
      dropped_total: 0,
      started_total: 0,
      completed_total: 0,
      failed_total: 0,
      drop_reason_counts: %{},
      queue_depth: 0,
      queue_depth_max: 0,
      active_workers: 0,
      active_workers_max: 0,
      durations_ms: []
    }
  end

  defp apply_event(state, [:mom, :pipeline, :enqueued], measurements, metadata) do
    count = measurement_count(measurements)
    update_queue_activity(%{state | enqueued_total: state.enqueued_total + count}, metadata)
  end

  defp apply_event(state, [:mom, :pipeline, :dropped], measurements, metadata) do
    count = measurement_count(measurements)
    reason = Map.get(metadata, :drop_reason, :unknown)

    state
    |> Map.update!(:dropped_total, &(&1 + count))
    |> Map.update!(:drop_reason_counts, fn counts -> Map.update(counts, reason, count, &(&1 + count)) end)
    |> update_queue_activity(metadata)
  end

  defp apply_event(state, [:mom, :pipeline, :started], measurements, metadata) do
    count = measurement_count(measurements)
    update_queue_activity(%{state | started_total: state.started_total + count}, metadata)
  end

  defp apply_event(state, [:mom, :pipeline, :completed], measurements, metadata) do
    state
    |> Map.update!(:completed_total, &(&1 + 1))
    |> add_duration_ms(measurements)
    |> update_queue_activity(metadata)
  end

  defp apply_event(state, [:mom, :pipeline, :failed], measurements, metadata) do
    state
    |> Map.update!(:failed_total, &(&1 + 1))
    |> add_duration_ms(measurements)
    |> update_queue_activity(metadata)
  end

  defp apply_event(state, _event, _measurements, _metadata), do: state

  defp update_queue_activity(state, metadata) do
    queue_depth = normalize_non_neg(Map.get(metadata, :queue_depth, state.queue_depth))
    active_workers = normalize_non_neg(Map.get(metadata, :active_workers, state.active_workers))

    %{
      state
      | queue_depth: queue_depth,
        active_workers: active_workers,
        queue_depth_max: max(queue_depth, state.queue_depth_max),
        active_workers_max: max(active_workers, state.active_workers_max)
    }
  end

  defp measurement_count(%{count: count}) when is_integer(count) and count > 0, do: count
  defp measurement_count(_), do: 1

  defp add_duration_ms(state, %{duration: duration}) when is_integer(duration) and duration >= 0 do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    durations = [duration_ms * 1.0 | state.durations_ms] |> Enum.take(@max_duration_samples)
    %{state | durations_ms: durations}
  end

  defp add_duration_ms(state, _measurements), do: state

  defp evaluate_slos(state) do
    metrics = derived_metrics(state)

    state
    |> maybe_emit_breach(:queue_depth, state.queue_depth, state.thresholds.queue_depth, metrics)
    |> maybe_emit_breach(:drop_rate, metrics.drop_rate, state.thresholds.drop_rate, metrics)
    |> maybe_emit_breach(
      :failure_rate,
      metrics.failure_rate,
      state.thresholds.failure_rate,
      metrics
    )
    |> maybe_emit_breach(
      :latency_p95_ms,
      metrics.latency_p95_ms,
      state.thresholds.latency_p95_ms,
      metrics
    )
  end

  defp maybe_emit_breach(state, metric, observed, threshold, metrics) do
    breached? = observed > threshold
    already_breached? = Map.get(state.breaches, metric, false)

    cond do
      breached? and not already_breached? ->
        metadata = %{
          metric: metric,
          observed: observed,
          threshold: threshold,
          queue_depth: state.queue_depth,
          drop_rate: metrics.drop_rate,
          failure_rate: metrics.failure_rate,
          latency_p95_ms: metrics.latency_p95_ms
        }

        :telemetry.execute([:mom, :alert, :slo_breach], %{count: 1}, metadata)
        Logger.warning("mom: alert slo_breach metric=#{metric} observed=#{observed} threshold=#{threshold}")
        put_in(state.breaches[metric], true)

      not breached? and already_breached? ->
        put_in(state.breaches[metric], false)

      true ->
        state
    end
  end

  defp export_metrics(state) do
    metrics = derived_metrics(state)

    lines = [
      "mom_pipeline_enqueued_total #{state.enqueued_total}",
      "mom_pipeline_dropped_total #{state.dropped_total}",
      "mom_pipeline_started_total #{state.started_total}",
      "mom_pipeline_completed_total #{state.completed_total}",
      "mom_pipeline_failed_total #{state.failed_total}"
      | drop_reason_lines(state.drop_reason_counts)
    ] ++
      [
        "mom_pipeline_queue_depth #{state.queue_depth}",
        "mom_pipeline_queue_depth_max #{state.queue_depth_max}",
        "mom_pipeline_active_workers #{state.active_workers}",
        "mom_pipeline_active_workers_max #{state.active_workers_max}",
        "mom_pipeline_drop_rate #{Float.round(metrics.drop_rate, 6)}",
        "mom_pipeline_failure_rate #{Float.round(metrics.failure_rate, 6)}",
        "mom_pipeline_latency_p95_ms #{Float.round(metrics.latency_p95_ms, 3)}"
      ]

    File.mkdir_p!(Path.dirname(state.export_path))
    File.write!(state.export_path, Enum.join(lines, "\n") <> "\n")
    state
  end

  defp drop_reason_lines(counts) do
    counts
    |> Enum.sort_by(fn {reason, _count} -> to_string(reason) end)
    |> Enum.map(fn {reason, count} ->
      ~s(mom_pipeline_drop_total{reason="#{reason}"} #{count})
    end)
  end

  defp derived_metrics(state) do
    drop_denominator = state.enqueued_total + state.dropped_total
    completion_denominator = state.completed_total + state.failed_total

    %{
      drop_rate: safe_ratio(state.dropped_total, drop_denominator),
      failure_rate: safe_ratio(state.failed_total, completion_denominator),
      latency_p95_ms: percentile(state.durations_ms, 0.95)
    }
  end

  defp snapshot_from_state(state) do
    metrics = derived_metrics(state)

    %{
      enqueued_total: state.enqueued_total,
      dropped_total: state.dropped_total,
      started_total: state.started_total,
      completed_total: state.completed_total,
      failed_total: state.failed_total,
      queue_depth: state.queue_depth,
      queue_depth_max: state.queue_depth_max,
      active_workers: state.active_workers,
      active_workers_max: state.active_workers_max,
      drop_rate: metrics.drop_rate,
      failure_rate: metrics.failure_rate,
      latency_p95_ms: metrics.latency_p95_ms
    }
  end

  defp percentile([], _quantile), do: 0.0

  defp percentile(samples, quantile) do
    sorted = Enum.sort(samples)
    index = min(length(sorted) - 1, max(0, ceil(length(sorted) * quantile) - 1))
    Enum.at(sorted, index) * 1.0
  end

  defp safe_ratio(_num, 0), do: 0.0
  defp safe_ratio(num, den), do: num / den

  defp schedule_export(interval_ms), do: Process.send_after(self(), :export_metrics, interval_ms)

  defp normalize_non_neg(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg(_), do: 0
end
