const { test, expect } = require("@playwright/test");
const { runAcceptanceScript } = require("./helpers/mix_runner");

test("mom checks in CI workflow manifests with required checks and flaky protections", async () => {
  const { result } = runAcceptanceScript("acceptance/scripts/mom_cli_ci_workflow_acceptance.exs");

  expect(result.ok).toBeTruthy();
  expect(result.required_checks).toEqual(["ci/exunit", "ci/playwright"]);
  expect(result.matched_checks).toContain("ci/exunit");
  expect(result.matched_checks).toContain("ci/playwright");
  expect(result.playwright_fail_on_flaky).toBeTruthy();
  expect(result.playwright_concurrency_report_path_set).toBeTruthy();
  expect(result.playwright_concurrency_artifact_uploaded).toBeTruthy();
});
