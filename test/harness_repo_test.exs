defmodule Mom.HarnessRepoTest do
  use ExUnit.Case, async: true

  alias Mom.HarnessRepo

  test "confirm_and_record stores private harness repo metadata and baseline scenarios" do
    record_path = unique_record_path()
    traceability_path = unique_traceability_path()
    evidence_path = unique_evidence_path()

    write_traceability!(
      traceability_path,
      [
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
    )

    fake_runner = fn
      "gh",
      ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
        {:ok,
         ~s({"nameWithOwner":"acme/harness","isPrivate":true,"url":"https://github.com/acme/harness","visibility":"PRIVATE"})}

      "gh", ["api", "repos/acme/harness/contents/" <> _path] ->
        {:ok, ~s({"path":"ok"})}

      "gh", ["api", "repos/acme/harness/branches/main/protection"] ->
        {:ok,
         ~s({"required_status_checks":{"contexts":["ci/exunit","ci/playwright"]},"required_pull_request_reviews":{"required_approving_review_count":1}})}
    end

    assert {:ok, record} =
             HarnessRepo.confirm_and_record("acme/harness", record_path,
               cmd_runner: fake_runner,
               recorded_at: "2026-02-19T00:00:00Z",
               baseline_error_path: "priv/replay/error_path.ex",
               baseline_diagnostics_path: "priv/replay/diagnostics_path.ex",
               traceability_path: traceability_path,
               branch_protection_evidence_path: evidence_path
             )

    assert record.name_with_owner == "acme/harness"
    assert record.is_private
    assert record.visibility == "PRIVATE"
    assert record.baseline_error_path == "priv/replay/error_path.ex"
    assert record.baseline_diagnostics_path == "priv/replay/diagnostics_path.ex"
    assert record.traceability_path == traceability_path
    assert record.traceability_mapped_capability_count == 10
    assert record.branch_protection_branch == "main"
    assert record.branch_protection_required_checks == ["ci/exunit", "ci/playwright"]
    assert record.branch_protection_min_approvals == 1
    assert record.branch_protection_evidence_path == evidence_path
    assert File.exists?(record_path)
    assert File.exists?(evidence_path)

    assert {:ok, loaded} = HarnessRepo.load_record(record_path)
    assert loaded.name_with_owner == "acme/harness"
    assert loaded.traceability_mapped_capability_count == 10

    {:ok, evidence_body} = File.read(evidence_path)
    {:ok, evidence} = Jason.decode(evidence_body)
    assert evidence["verified"] == true
    assert evidence["repo"] == "acme/harness"
    assert evidence["branch"] == "main"
    assert evidence["required_checks"] == ["ci/exunit", "ci/playwright"]
    assert evidence["observed_checks"] == ["ci/exunit", "ci/playwright"]
    assert evidence["required_min_approvals"] == 1
    assert evidence["observed_min_approvals"] == 1

    assert evidence["ci_workflow_verification"]["matched_checks"] == [
             "ci/exunit",
             "ci/playwright"
           ]

    assert evidence["ci_workflow_verification"]["playwright_fail_on_flaky"] == true
  end

  test "confirm_and_record rejects non-private harness repo" do
    record_path = unique_record_path()

    fake_runner = fn
      "gh",
      ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
        {:ok,
         ~s({"nameWithOwner":"acme/harness","isPrivate":false,"url":"https://github.com/acme/harness","visibility":"PUBLIC"})}
    end

    assert {:error, "harness repository must be private"} =
             HarnessRepo.confirm_and_record("acme/harness", record_path, cmd_runner: fake_runner)
  end

  test "load_record validates required fields" do
    record_path = unique_record_path()
    File.write!(record_path, ~s({"name_with_owner":"acme/harness","is_private":true}))

    assert {:error, "harness record is missing required field: url"} =
             HarnessRepo.load_record(record_path)
  end

  test "confirm_and_record rejects missing baseline scenario path in harness repo" do
    record_path = unique_record_path()

    fake_runner = fn
      "gh",
      ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
        {:ok,
         ~s({"nameWithOwner":"acme/harness","isPrivate":true,"url":"https://github.com/acme/harness","visibility":"PRIVATE"})}

      "gh", ["api", "repos/acme/harness/contents/priv/replay/error_path.ex"] ->
        {:ok, ~s({"path":"priv/replay/error_path.ex"})}

      "gh", ["api", "repos/acme/harness/contents/priv/replay/missing_diagnostics_path.ex"] ->
        {:error, "404 Not Found"}

      "gh", ["api", "repos/acme/harness/contents/" <> _path] ->
        {:ok, ~s({"path":"ok"})}
    end

    assert {:error,
            "harness baseline scenario path not found: priv/replay/missing_diagnostics_path.ex"} =
             HarnessRepo.confirm_and_record("acme/harness", record_path,
               cmd_runner: fake_runner,
               baseline_error_path: "priv/replay/error_path.ex",
               baseline_diagnostics_path: "priv/replay/missing_diagnostics_path.ex"
             )
  end

  test "confirm_and_record rejects traceability matrix missing required capabilities" do
    record_path = unique_record_path()
    traceability_path = unique_traceability_path()

    write_traceability!(
      traceability_path,
      [
        %{
          "capability_id" => "pipeline_concurrency",
          "capability_name" => "Concurrent pipeline dispatch",
          "scenario_path" => "priv/replay/concurrency/pipeline_concurrency.exs",
          "playwright_spec_path" => "playwright/tests/pipeline_concurrency.spec.ts",
          "mode" => "burst"
        }
      ]
    )

    fake_runner = fn
      "gh",
      ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
        {:ok,
         ~s({"nameWithOwner":"acme/harness","isPrivate":true,"url":"https://github.com/acme/harness","visibility":"PRIVATE"})}

      "gh", ["api", "repos/acme/harness/contents/" <> _path] ->
        {:ok, ~s({"path":"ok"})}

      "gh", ["api", "repos/acme/harness/branches/main/protection"] ->
        {:ok,
         ~s({"required_status_checks":{"contexts":["ci/exunit","ci/playwright"]},"required_pull_request_reviews":{"required_approving_review_count":1}})}
    end

    assert {:error, reason} =
             HarnessRepo.confirm_and_record("acme/harness", record_path,
               cmd_runner: fake_runner,
               baseline_error_path: "priv/replay/error_path.ex",
               baseline_diagnostics_path: "priv/replay/diagnostics_path.ex",
               traceability_path: traceability_path
             )

    assert String.contains?(reason, "harness traceability matrix is missing capability mappings")
  end

  test "confirm_and_record rejects missing required branch protection status checks" do
    record_path = unique_record_path()
    traceability_path = unique_traceability_path()

    write_traceability!(traceability_path, full_traceability_entries())

    fake_runner = fn
      "gh",
      ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
        {:ok,
         ~s({"nameWithOwner":"acme/harness","isPrivate":true,"url":"https://github.com/acme/harness","visibility":"PRIVATE"})}

      "gh", ["api", "repos/acme/harness/contents/" <> _path] ->
        {:ok, ~s({"path":"ok"})}

      "gh", ["api", "repos/acme/harness/branches/main/protection"] ->
        {:ok,
         ~s({"required_status_checks":{"contexts":["ci/exunit"]},"required_pull_request_reviews":{"required_approving_review_count":1}})}
    end

    assert {:error, reason} =
             HarnessRepo.confirm_and_record("acme/harness", record_path,
               cmd_runner: fake_runner,
               baseline_error_path: "priv/replay/error_path.ex",
               baseline_diagnostics_path: "priv/replay/diagnostics_path.ex",
               traceability_path: traceability_path
             )

    assert String.contains?(
             reason,
             "harness branch protection is missing required status checks: ci/playwright"
           )
  end

  test "confirm_and_record rejects insufficient required branch protection approvals" do
    record_path = unique_record_path()
    traceability_path = unique_traceability_path()

    write_traceability!(traceability_path, full_traceability_entries())

    fake_runner = fn
      "gh",
      ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
        {:ok,
         ~s({"nameWithOwner":"acme/harness","isPrivate":true,"url":"https://github.com/acme/harness","visibility":"PRIVATE"})}

      "gh", ["api", "repos/acme/harness/contents/" <> _path] ->
        {:ok, ~s({"path":"ok"})}

      "gh", ["api", "repos/acme/harness/branches/main/protection"] ->
        {:ok,
         ~s({"required_status_checks":{"contexts":["ci/exunit","ci/playwright"]},"required_pull_request_reviews":{"required_approving_review_count":0}})}
    end

    assert {:error, reason} =
             HarnessRepo.confirm_and_record("acme/harness", record_path,
               cmd_runner: fake_runner,
               baseline_error_path: "priv/replay/error_path.ex",
               baseline_diagnostics_path: "priv/replay/diagnostics_path.ex",
               traceability_path: traceability_path,
               min_approvals: 1
             )

    assert String.contains?(
             reason,
             "harness branch protection requires at least 1 approving review(s); found 0"
           )
  end

  test "confirm_and_record rejects invalid ci workflow reliability wiring" do
    record_path = unique_record_path()
    traceability_path = unique_traceability_path()
    workflows_path = unique_workflows_path()
    File.mkdir_p!(workflows_path)
    write_traceability!(traceability_path, full_traceability_entries())

    File.write!(
      Path.join(workflows_path, "ci-exunit.yml"),
      """
      name: ci/exunit
      jobs:
        exunit:
          name: ci/exunit
          steps:
            - run: mix mom.doctor --fail-on-error
      """
    )

    File.write!(
      Path.join(workflows_path, "ci-playwright.yml"),
      """
      name: ci/playwright
      jobs:
        playwright:
          name: ci/playwright
          steps:
            - run: mix mom.doctor --fail-on-error
      """
    )

    fake_runner = fn
      "gh",
      ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
        {:ok,
         ~s({"nameWithOwner":"acme/harness","isPrivate":true,"url":"https://github.com/acme/harness","visibility":"PRIVATE"})}

      "gh", ["api", "repos/acme/harness/contents/" <> _path] ->
        {:ok, ~s({"path":"ok"})}

      "gh", ["api", "repos/acme/harness/branches/main/protection"] ->
        {:ok,
         ~s({"required_status_checks":{"contexts":["ci/exunit","ci/playwright"]},"required_pull_request_reviews":{"required_approving_review_count":1}})}
    end

    assert {:error, reason} =
             HarnessRepo.confirm_and_record("acme/harness", record_path,
               cmd_runner: fake_runner,
               baseline_error_path: "priv/replay/error_path.ex",
               baseline_diagnostics_path: "priv/replay/diagnostics_path.ex",
               traceability_path: traceability_path,
               ci_workflows_path: workflows_path
             )

    assert String.contains?(reason, "MOM_ACCEPTANCE_FAIL_ON_FLAKY")
  end

  defp unique_record_path do
    Path.join(System.tmp_dir!(), "mom-harness-record-#{System.unique_integer([:positive])}.json")
  end

  defp unique_traceability_path do
    Path.join(
      System.tmp_dir!(),
      "mom-harness-traceability-#{System.unique_integer([:positive])}.json"
    )
  end

  defp unique_evidence_path do
    Path.join(
      System.tmp_dir!(),
      "mom-harness-branch-protection-evidence-#{System.unique_integer([:positive])}.json"
    )
  end

  defp unique_workflows_path do
    Path.join(
      System.tmp_dir!(),
      "mom-ci-workflows-#{System.unique_integer([:positive])}"
    )
  end

  defp write_traceability!(path, entries) do
    payload = %{"capabilities" => entries}
    File.write!(path, Jason.encode!(payload, pretty: true))
  end

  defp full_traceability_entries do
    [
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
  end
end
