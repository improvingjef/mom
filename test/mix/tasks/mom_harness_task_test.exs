defmodule Mix.Tasks.Mom.HarnessTaskTest do
  use ExUnit.Case, async: true

  test "parse_args accepts repo, record path, baseline scenario paths, and traceability path" do
    assert {:ok, opts} =
             Mix.Tasks.Mom.Harness.parse_args([
               "--repo",
               "acme/harness",
               "--record-path",
               "acceptance/harness_repo.json",
               "--baseline-error-path",
               "priv/replay/error_path.ex",
               "--baseline-diagnostics-path",
               "priv/replay/diagnostics_path.ex",
               "--traceability-path",
               "acceptance/harness_traceability.json",
               "--branch-protection-branch",
               "main",
               "--required-checks",
               "ci/exunit,ci/playwright",
               "--min-approvals",
               "1",
               "--branch-protection-evidence-path",
               "acceptance/harness_branch_protection_evidence.json"
             ])

    assert opts.repo == "acme/harness"
    assert opts.record_path == "acceptance/harness_repo.json"
    assert opts.baseline_error_path == "priv/replay/error_path.ex"
    assert opts.baseline_diagnostics_path == "priv/replay/diagnostics_path.ex"
    assert opts.traceability_path == "acceptance/harness_traceability.json"
    assert opts.branch_protection_branch == "main"
    assert opts.required_checks == ["ci/exunit", "ci/playwright"]
    assert opts.min_approvals == 1
    assert opts.branch_protection_evidence_path == "acceptance/harness_branch_protection_evidence.json"
  end

  test "parse_args defaults traceability path" do
    assert {:ok, opts} =
             Mix.Tasks.Mom.Harness.parse_args([
               "--repo",
               "acme/harness",
               "--baseline-error-path",
               "priv/replay/error_path.ex",
               "--baseline-diagnostics-path",
               "priv/replay/diagnostics_path.ex"
             ])

    assert opts.traceability_path == "acceptance/harness_traceability.json"
    assert opts.branch_protection_branch == "main"
    assert opts.required_checks == ["ci/exunit", "ci/playwright"]
    assert opts.min_approvals == 1
    assert opts.branch_protection_evidence_path == "acceptance/harness_branch_protection_evidence.json"
  end

  test "parse_args requires repo" do
    assert {:error, "--repo is required"} = Mix.Tasks.Mom.Harness.parse_args([])
  end

  test "parse_args requires baseline scenario paths" do
    assert {:error, "--baseline-error-path is required"} =
             Mix.Tasks.Mom.Harness.parse_args(["--repo", "acme/harness"])

    assert {:error, "--baseline-diagnostics-path is required"} =
             Mix.Tasks.Mom.Harness.parse_args([
               "--repo",
               "acme/harness",
               "--baseline-error-path",
               "priv/replay/error_path.ex"
             ])
  end

  test "parse_args validates required checks and minimum approvals" do
    assert {:error, "--required-checks must include at least one check name"} =
             Mix.Tasks.Mom.Harness.parse_args([
               "--repo",
               "acme/harness",
               "--baseline-error-path",
               "priv/replay/error_path.ex",
               "--baseline-diagnostics-path",
               "priv/replay/diagnostics_path.ex",
               "--required-checks",
               ","
             ])

    assert {:error, "--min-approvals must be a non-negative integer"} =
             Mix.Tasks.Mom.Harness.parse_args([
               "--repo",
               "acme/harness",
               "--baseline-error-path",
               "priv/replay/error_path.ex",
               "--baseline-diagnostics-path",
               "priv/replay/diagnostics_path.ex",
               "--min-approvals",
               "-1"
             ])
  end
end
