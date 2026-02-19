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

    budget_handler_id = "#{handler_id}-budget"

    :ok =
      :telemetry.attach(
        budget_handler_id,
        [:mom, :alert, :error_budget_breach],
        fn event, _measurements, metadata, pid ->
          send(pid, {:error_budget_breach, event, metadata})
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
          latency_p95_ms_threshold: 100,
          triage_latency_p95_ms_target: 100,
          queue_durability_target: 0.99,
          pr_turnaround_p95_ms_target: 1_000,
          triage_latency_overage_budget_rate: 0.1,
          queue_loss_budget_rate: 0.01,
          pr_turnaround_overage_budget_rate: 0.05
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

      :telemetry.execute(
        [:mom, :audit, :github_issue_created],
        %{count: 1},
        %{occurred_at_ms: 1_000}
      )

      :telemetry.execute(
        [:mom, :audit, :github_pr_created],
        %{count: 1},
        %{occurred_at_ms: 2_500}
      )

      :ok = Observability.sync_export(pid)
      max_export_retries = 25
      {metrics, post_export_retry_attempts} = wait_for_expected_metrics(export_path, max_export_retries)
      snapshot = Observability.snapshot(pid)
      breaches = collect_breaches([])
      budget_breaches = collect_budget_breaches([])

      result = %{
        has_enqueued_metric: String.contains?(metrics, "mom_pipeline_enqueued_total 1"),
        has_dropped_metric: String.contains?(metrics, "mom_pipeline_dropped_total 1"),
        has_failed_metric: String.contains?(metrics, "mom_pipeline_failed_total 1"),
        has_drop_rate_metric: String.contains?(metrics, "mom_pipeline_drop_rate 0.5"),
        has_failure_rate_metric: String.contains?(metrics, "mom_pipeline_failure_rate 1.0"),
        has_latency_metric: String.contains?(metrics, "mom_pipeline_latency_p95_ms 250.0"),
        has_queue_durability_metric: String.contains?(metrics, "mom_sla_queue_durability 0.5"),
        has_pr_turnaround_metric: String.contains?(metrics, "mom_sla_pr_turnaround_p95_ms "),
        has_error_budget_queue_loss_metric:
          String.contains?(metrics, "mom_error_budget_queue_loss_rate 0.5"),
        saw_queue_depth_breach: :queue_depth in breaches,
        saw_drop_rate_breach: :drop_rate in breaches,
        saw_failure_rate_breach: :failure_rate in breaches,
        saw_latency_breach: :latency_p95_ms in breaches,
        saw_latency_budget_breach: :triage_latency_overage_rate in budget_breaches,
        saw_queue_budget_breach: :queue_loss_rate in budget_breaches,
        saw_pr_turnaround_budget_breach: :pr_turnaround_overage_rate in budget_breaches,
        post_export_assertions_passed: true,
        post_export_retry_attempts: post_export_retry_attempts,
        post_export_retry_limit: max_export_retries + 1,
        snapshot_drop_rate: snapshot.drop_rate,
        snapshot_failure_rate: snapshot.failure_rate,
        snapshot_queue_durability: snapshot.queue_durability,
        snapshot_pr_turnaround_p95_ms: snapshot.pr_turnaround_p95_ms
      }

      IO.puts("RESULT_JSON:" <> Jason.encode!(result))
    after
      :telemetry.detach(handler_id)
      :telemetry.detach(budget_handler_id)
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

  defp collect_budget_breaches(acc) do
    receive do
      {:error_budget_breach, [:mom, :alert, :error_budget_breach], %{metric: metric}} ->
        collect_budget_breaches([metric | acc])
    after
      200 ->
        Enum.uniq(acc)
    end
  end

  defp wait_for_expected_metrics(export_path, retries, attempts \\ 1)

  defp wait_for_expected_metrics(export_path, retries, attempts) do
    expected_snippets = [
      "mom_pipeline_enqueued_total 1",
      "mom_pipeline_dropped_total 1",
      "mom_pipeline_failed_total 1",
      "mom_pipeline_drop_rate 0.5",
      "mom_pipeline_failure_rate 1.0",
      "mom_pipeline_latency_p95_ms 250.0",
      "mom_sla_queue_durability 0.5",
      "mom_sla_pr_turnaround_p95_ms ",
      "mom_error_budget_queue_loss_rate 0.5",
      "mom_error_budget_pr_turnaround_overage_rate 1.0"
    ]

    case File.read(export_path) do
      {:ok, contents} ->
        if Enum.all?(expected_snippets, &String.contains?(contents, &1)) do
          {contents, attempts}
        else
          retry_expected_metrics(export_path, retries, attempts)
        end

      {:error, _reason} ->
        retry_expected_metrics(export_path, retries, attempts)
    end
  end

  defp retry_expected_metrics(_export_path, 0, attempts) do
    raise("timed out waiting for full metrics export after #{attempts} attempts")
  end

  defp retry_expected_metrics(export_path, retries, attempts) do
    Process.sleep(20)
    wait_for_expected_metrics(export_path, retries - 1, attempts + 1)
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
