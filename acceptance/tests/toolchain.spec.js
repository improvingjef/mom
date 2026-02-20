const { test, expect } = require("@playwright/test");
const { runAcceptanceScript } = require("./helpers/mix_runner");

test("mom doctor reports actionable toolchain preflight issues and bootstrap manifests", async () => {
  const { result } = runAcceptanceScript(
    "acceptance/scripts/mom_cli_toolchain_doctor_bootstrap_acceptance.exs"
  );

  expect(result.failing_status).toBe("error");
  expect(result.failing_has_node_error).toBeTruthy();
  expect(result.bootstrap_tool_versions_exists).toBeTruthy();
  expect(result.bootstrap_mise_exists).toBeTruthy();
  expect(result.healthy_status).toBe("ok");
  expect(result.healthy_manifest_checks_ok).toBeTruthy();
});

test("mom enforces aligned runtime support policy across manifests, mix requirement, and CI pins", async () => {
  const { result } = runAcceptanceScript(
    "acceptance/scripts/mom_cli_toolchain_policy_alignment_acceptance.exs"
  );

  expect(result.doctor_status).toBe("ok");
  expect(result.required_elixir_version).toBe("1.19.4");
  expect(result.mix_exs_aligned).toBeTruthy();
  expect(result.tool_versions_aligned).toBeTruthy();
  expect(result.mise_aligned).toBeTruthy();
  expect(result.ci_exunit_aligned).toBeTruthy();
  expect(result.ci_playwright_aligned).toBeTruthy();
});
