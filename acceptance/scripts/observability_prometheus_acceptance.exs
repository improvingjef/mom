defmodule Mom.Acceptance.ObservabilityPrometheusScript do
  alias Mom.Observability

  def run do
    export_path = export_path()
    parent = self()
    handler_id = "mom-observability-acceptance-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:mom, :alert, :slo_breach],
        fn event, _measurements, metadata, pid ->
          send(pid, {:slo_breach, event, metadata})
        end,
        parent
      )

    try do
      {:ok, pid} =
        Observability.start_link(
          export_path: export_path,
          export_interval_ms: 10,
          queue_depth_threshold: 1,
          drop_rate_threshold: 0.25,
          failure_rate_threshold: 0.25,
          latency_p95_ms_threshold: 100
        )

      :telemetry.execute(
        [:mom, :pipeline, :enqueued],
        %{count: 1},
        %{job_type: :error_event, queue_depth: 2, active_workers: 0}
      )

      :telemetry.execute(
        [:mom, :pipeline, :dropped],
        %{count: 1},
        %{drop_reason: :newest, queue_depth: 2, active_workers: 0}
      )

      :telemetry.execute(
        [:mom, :pipeline, :failed],
        %{duration: System.convert_time_unit(250, :millisecond, :native)},
        %{job_type: :error_event, queue_depth: 0, active_workers: 0, reason: :boom}
      )

      wait_for(fn ->
        case File.read(export_path) do
          {:ok, contents} -> String.contains?(contents, "mom_pipeline_enqueued_total 1")
          _ -> false
        end
      end)

      metrics = File.read!(export_path)
      snapshot = Observability.snapshot(pid)
      breaches = collect_breaches([])

      result = %{
        has_enqueued_metric: String.contains?(metrics, "mom_pipeline_enqueued_total 1"),
        has_dropped_metric: String.contains?(metrics, "mom_pipeline_dropped_total 1"),
        has_failed_metric: String.contains?(metrics, "mom_pipeline_failed_total 1"),
        has_drop_rate_metric: String.contains?(metrics, "mom_pipeline_drop_rate 0.5"),
        has_failure_rate_metric: String.contains?(metrics, "mom_pipeline_failure_rate 1.0"),
        has_latency_metric: String.contains?(metrics, "mom_pipeline_latency_p95_ms 250.0"),
        saw_queue_depth_breach: :queue_depth in breaches,
        saw_drop_rate_breach: :drop_rate in breaches,
        saw_failure_rate_breach: :failure_rate in breaches,
        saw_latency_breach: :latency_p95_ms in breaches,
        snapshot_drop_rate: snapshot.drop_rate,
        snapshot_failure_rate: snapshot.failure_rate
      }

      IO.puts("RESULT_JSON:" <> Jason.encode!(result))
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_breaches(acc) do
    receive do
      {:slo_breach, [:mom, :alert, :slo_breach], %{metric: metric}} ->
        collect_breaches([metric | acc])
    after
      200 ->
        Enum.uniq(acc)
    end
  end

  defp wait_for(fun, retries \\ 500)

  defp wait_for(fun, 0) do
    if fun.(), do: :ok, else: raise("timed out waiting for condition")
  end

  defp wait_for(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_for(fun, retries - 1)
    end
  end

  defp export_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "mom-observability-acceptance-#{System.unique_integer([:positive])}.prom"
      )

    File.rm(path)
    path
  end
end

Mom.Acceptance.ObservabilityPrometheusScript.run()
