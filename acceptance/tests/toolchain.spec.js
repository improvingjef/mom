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
