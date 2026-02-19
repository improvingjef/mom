Mix.Task.run("app.start")

record_path =
  Path.join(
    System.tmp_dir!(),
    "mom-harness-acceptance-#{System.unique_integer([:positive])}.json"
  )

traceability_path =
  Path.join(
    System.tmp_dir!(),
    "mom-harness-traceability-acceptance-#{System.unique_integer([:positive])}.json"
  )

File.rm(record_path)

traceability = %{
  "capabilities" => [
    %{
      "capability_id" => "pipeline_concurrency",
      "capability_name" => "Concurrent pipeline dispatch",
      "scenario_path" => "priv/replay/concurrency/pipeline_concurrency.exs",
      "playwright_spec_path" => "playwright/tests/pipeline_concurrency.spec.ts",
      "mode" => "burst"
    },
    %{
      "capability_id" => "job_timeout_cancellation",
      "capability_name" => "Timed out jobs release capacity",
      "scenario_path" => "priv/replay/concurrency/job_timeout_cancellation.exs",
      "playwright_spec_path" => "playwright/tests/job_timeout_cancellation.spec.ts",
      "mode" => "burst"
    },
    %{
      "capability_id" => "inflight_signature_dedupe",
      "capability_name" => "In-flight signature dedupe",
      "scenario_path" => "priv/replay/concurrency/inflight_signature_dedupe.exs",
      "playwright_spec_path" => "playwright/tests/inflight_signature_dedupe.spec.ts",
      "mode" => "burst"
    },
    %{
      "capability_id" => "pipeline_telemetry_visibility",
      "capability_name" => "Pipeline telemetry visibility",
      "scenario_path" => "priv/replay/observability/pipeline_telemetry_visibility.exs",
      "playwright_spec_path" => "playwright/tests/pipeline_telemetry_visibility.spec.ts",
      "mode" => "baseline"
    },
    %{
      "capability_id" => "durable_queue_replay",
      "capability_name" => "Durable queue replay on restart",
      "scenario_path" => "priv/replay/reliability/durable_queue_replay.exs",
      "playwright_spec_path" => "playwright/tests/durable_queue_replay.spec.ts",
      "mode" => "burst"
    },
    %{
      "capability_id" => "multi_tenant_fairness",
      "capability_name" => "Multi-tenant fair scheduling",
      "scenario_path" => "priv/replay/multi_tenant/fair_scheduler.exs",
      "playwright_spec_path" => "playwright/tests/multi_tenant_fairness.spec.ts",
      "mode" => "burst"
    },
    %{
      "capability_id" => "security_allowlist_enforcement",
      "capability_name" => "Repo allowlist enforcement",
      "scenario_path" => "priv/replay/security/allowlist_enforcement.exs",
      "playwright_spec_path" => "playwright/tests/security_allowlist_enforcement.spec.ts",
      "mode" => "baseline"
    },
    %{
      "capability_id" => "machine_identity_enforcement",
      "capability_name" => "Machine identity enforcement",
      "scenario_path" => "priv/replay/security/machine_identity_enforcement.exs",
      "playwright_spec_path" => "playwright/tests/machine_identity_enforcement.spec.ts",
      "mode" => "baseline"
    },
    %{
      "capability_id" => "egress_policy_fail_closed",
      "capability_name" => "Egress policy fail-closed",
      "scenario_path" => "priv/replay/security/egress_policy_fail_closed.exs",
      "playwright_spec_path" => "playwright/tests/egress_policy_fail_closed.spec.ts",
      "mode" => "baseline"
    },
    %{
      "capability_id" => "observability_slo_alerts",
      "capability_name" => "SLO alerts and metrics export",
      "scenario_path" => "priv/replay/observability/observability_slo_alerts.exs",
      "playwright_spec_path" => "playwright/tests/observability_slo_alerts.spec.ts",
      "mode" => "baseline"
    }
  ]
}

File.write!(traceability_path, Jason.encode!(traceability, pretty: true))

fake_runner = fn
  "gh", ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
    {:ok,
     ~s({"nameWithOwner":"acme/harness","isPrivate":true,"url":"https://github.com/acme/harness","visibility":"PRIVATE"})}

  "gh", ["api", "repos/acme/harness/contents/" <> _path] ->
    {:ok, ~s({"path":"ok"})}
end

{:ok, record} =
  Mom.HarnessRepo.confirm_and_record("acme/harness", record_path,
    cmd_runner: fake_runner,
    recorded_at: "2026-02-19T00:00:00Z",
    baseline_error_path: "priv/replay/error_path.ex",
    baseline_diagnostics_path: "priv/replay/diagnostics_path.ex",
    traceability_path: traceability_path
  )

{:ok, loaded} = Mom.HarnessRepo.load_record(record_path)

IO.puts(
  "RESULT_JSON:" <>
    Jason.encode!(%{
      name_with_owner: record.name_with_owner,
      is_private: record.is_private,
      visibility: record.visibility,
      baseline_error_path: record.baseline_error_path,
      baseline_diagnostics_path: record.baseline_diagnostics_path,
      traceability_path: record.traceability_path,
      traceability_mapped_capability_count: record.traceability_mapped_capability_count,
      loaded_matches: loaded.name_with_owner == "acme/harness",
      loaded_count_matches: loaded.traceability_mapped_capability_count == 10
    })
)
