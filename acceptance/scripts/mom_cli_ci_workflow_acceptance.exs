Mix.Task.run("app.start")

required_checks = ["ci/exunit", "ci/playwright"]
workflows_path = ".github/workflows"

result =
  case Mom.CIWorkflow.verify_required_checks(required_checks, workflows_path: workflows_path) do
    {:ok, evidence} ->
      %{
        ok: true,
        required_checks: required_checks,
        workflows_path: workflows_path,
        matched_checks: evidence.matched_checks,
        playwright_fail_on_flaky: evidence.playwright_fail_on_flaky,
        playwright_concurrency_report_path_set: evidence.playwright_concurrency_report_path_set,
        playwright_concurrency_artifact_uploaded: evidence.playwright_concurrency_artifact_uploaded,
        toolchain_drift_gate_enforced: evidence.toolchain_drift_gate_enforced
      }

    {:error, reason} ->
      %{
        ok: false,
        required_checks: required_checks,
        workflows_path: workflows_path,
        error: reason
      }
  end

IO.puts("RESULT_JSON:" <> Jason.encode!(result))
