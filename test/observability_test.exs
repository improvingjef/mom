defmodule Mom.ObservabilityTest do
  use ExUnit.Case, async: false

  alias Mom.Observability

  test "exports pipeline metrics in prometheus format" do
    export_path = unique_export_path()

    pid =
      start_supervised!(
        {Observability,
         export_path: export_path,
         export_interval_ms: 10,
         queue_depth_threshold: 999,
         drop_rate_threshold: 1.0,
         failure_rate_threshold: 1.0,
         latency_p95_ms_threshold: 999_999}
      )

    :telemetry.execute(
      [:mom, :pipeline, :enqueued],
      %{count: 1},
      %{job_type: :error_event, queue_depth: 1, active_workers: 0}
    )

    :telemetry.execute(
      [:mom, :pipeline, :started],
      %{count: 1},
      %{job_type: :error_event, queue_depth: 0, active_workers: 1}
    )

    :telemetry.execute(
      [:mom, :pipeline, :completed],
      %{duration: System.convert_time_unit(120, :millisecond, :native)},
      %{job_type: :error_event, queue_depth: 0, active_workers: 0}
    )

    :telemetry.execute(
      [:mom, :pipeline, :dropped],
      %{count: 1},
      %{drop_reason: :newest, queue_depth: 1, active_workers: 0}
    )

    :telemetry.execute(
      [:mom, :pipeline, :failed],
      %{duration: System.convert_time_unit(40, :millisecond, :native)},
      %{job_type: :error_event, queue_depth: 0, active_workers: 0, reason: :boom}
    )

    eventually(fn ->
      assert File.exists?(export_path)
      contents = File.read!(export_path)
      assert contents =~ "mom_pipeline_enqueued_total 1"
      assert contents =~ "mom_pipeline_started_total 1"
      assert contents =~ "mom_pipeline_completed_total 1"
      assert contents =~ "mom_pipeline_failed_total 1"
      assert contents =~ "mom_pipeline_dropped_total 1"
      assert contents =~ ~s(mom_pipeline_drop_total{reason="newest"} 1)
      assert contents =~ "mom_pipeline_queue_depth 0"
      assert contents =~ "mom_pipeline_active_workers 0"
      assert contents =~ "mom_pipeline_queue_depth_max 1"
      assert contents =~ "mom_pipeline_drop_rate 0.5"
      assert contents =~ "mom_pipeline_failure_rate 0.5"
      assert contents =~ "mom_pipeline_latency_p95_ms 120.0"
    end)

    snapshot = Observability.snapshot(pid)
    assert snapshot.enqueued_total == 1
    assert snapshot.completed_total == 1
    assert snapshot.failed_total == 1
    assert snapshot.dropped_total == 1
    assert snapshot.drop_rate == 0.5
    assert snapshot.failure_rate == 0.5
    assert snapshot.latency_p95_ms == 120.0
    assert snapshot.queue_durability == 0.5
  end

  test "emits SLO breach telemetry events when thresholds are exceeded" do
    export_path = unique_export_path()
    handler_id = "mom-observability-slo-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:mom, :alert, :slo_breach],
        fn event, measurements, metadata, pid ->
          send(pid, {:slo_breach, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    _pid =
      start_supervised!(
        {Observability,
         export_path: export_path,
         export_interval_ms: 10,
         queue_depth_threshold: 1,
         drop_rate_threshold: 0.25,
         failure_rate_threshold: 0.25,
         latency_p95_ms_threshold: 100}
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

    assert_receive {:slo_breach, [:mom, :alert, :slo_breach], %{count: 1}, metadata}
    assert metadata.metric in [:queue_depth, :drop_rate, :failure_rate, :latency_p95_ms]

    assert_receive {:slo_breach, [:mom, :alert, :slo_breach], %{count: 1}, metadata}
    assert metadata.metric in [:queue_depth, :drop_rate, :failure_rate, :latency_p95_ms]

    assert_receive {:slo_breach, [:mom, :alert, :slo_breach], %{count: 1}, metadata}
    assert metadata.metric in [:queue_depth, :drop_rate, :failure_rate, :latency_p95_ms]

    assert_receive {:slo_breach, [:mom, :alert, :slo_breach], %{count: 1}, metadata}
    assert metadata.metric in [:queue_depth, :drop_rate, :failure_rate, :latency_p95_ms]
  end

  test "exports sla targets and emits error-budget breach telemetry events" do
    export_path = unique_export_path()
    handler_id = "mom-observability-budget-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:mom, :alert, :error_budget_breach],
        fn event, measurements, metadata, pid ->
          send(pid, {:error_budget_breach, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    pid =
      start_supervised!(
        {Observability,
         export_path: export_path,
         export_interval_ms: 10,
         triage_latency_p95_ms_target: 100,
         queue_durability_target: 0.99,
         pr_turnaround_p95_ms_target: 1_000,
         triage_latency_overage_budget_rate: 0.1,
         queue_loss_budget_rate: 0.01,
         pr_turnaround_overage_budget_rate: 0.05}
      )

    :telemetry.execute(
      [:mom, :pipeline, :enqueued],
      %{count: 1},
      %{job_type: :error_event, queue_depth: 1, active_workers: 0}
    )

    :telemetry.execute(
      [:mom, :pipeline, :completed],
      %{duration: System.convert_time_unit(250, :millisecond, :native)},
      %{job_type: :error_event, queue_depth: 0, active_workers: 0}
    )

    :telemetry.execute(
      [:mom, :pipeline, :dropped],
      %{count: 1},
      %{drop_reason: :newest, queue_depth: 0, active_workers: 0}
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

    assert_receive {:error_budget_breach, [:mom, :alert, :error_budget_breach], %{count: 1},
                    %{metric: :triage_latency_overage_rate}}

    assert_receive {:error_budget_breach, [:mom, :alert, :error_budget_breach], %{count: 1},
                    %{metric: :queue_loss_rate}}

    assert_receive {:error_budget_breach, [:mom, :alert, :error_budget_breach], %{count: 1},
                    %{metric: :pr_turnaround_overage_rate}}

    eventually(fn ->
      contents = File.read!(export_path)
      assert contents =~ "mom_sla_target_triage_latency_p95_ms 100"
      assert contents =~ "mom_sla_target_queue_durability 0.99"
      assert contents =~ "mom_sla_target_pr_turnaround_p95_ms 1000"
      assert contents =~ "mom_sla_queue_durability 0.5"
      assert contents =~ "mom_sla_pr_turnaround_p95_ms "
      assert contents =~ "mom_error_budget_queue_loss_rate 0.5"
    end)

    snapshot = Observability.snapshot(pid)
    assert snapshot.queue_durability == 0.5
    assert snapshot.pr_turnaround_p95_ms == 1500.0
  end

  defp eventually(fun, retries \\ 40)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, retries - 1)
  end

  defp unique_export_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "mom-observability-#{System.unique_integer([:positive])}.prom"
      )

    File.rm(path)
    path
  end
end
