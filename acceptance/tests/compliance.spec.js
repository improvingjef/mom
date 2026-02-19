const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");
const path = require("node:path");

test("mom enforces compliance controls for retention, evidence hooks, and PII policy", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_compliance_acceptance.exs"],
    {
      cwd: repoRoot,
      env: { ...process.env, ASDF_ELIXIR_VERSION: "1.19.4-otp-28" }
    }
  ).toString();

  const marker = output
    .split("\n")
    .find((line) => line.startsWith("RESULT_JSON:"));

  expect(marker).toBeTruthy();
  const result = JSON.parse(marker.replace("RESULT_JSON:", ""));

  expect(result.audit_retention_days).toBe(1);
  expect(result.soc2_evidence_path_set).toBeTruthy();
  expect(result.pii_handling_policy).toBe("drop");
  expect(result.has_old_record).toBeFalsy();
  expect(result.has_new_record).toBeTruthy();
  expect(result.evidence_redacted_token).toBeFalsy();
  expect(result.evidence_has_token_key).toBeFalsy();
  expect(result.evidence_has_authorization_key).toBeFalsy();
  expect(result.log_has_token_key).toBeFalsy();
  expect(result.log_has_authorization_key).toBeFalsy();
  expect(result.log_contains_secret).toBeFalsy();
});

test("mom CLI generates a validated disaster recovery runbook", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_runbook_acceptance.exs"],
    {
      cwd: repoRoot,
      env: { ...process.env, ASDF_ELIXIR_VERSION: "1.19.4-otp-28" }
    }
  ).toString();

  const marker = output
    .split("\n")
    .find((line) => line.startsWith("RESULT_JSON:"));

  expect(marker).toBeTruthy();
  const result = JSON.parse(marker.replace("RESULT_JSON:", ""));

  expect(result.output_exists).toBeTruthy();
  expect(result.generated_on_present).toBeTruthy();
  expect(result.has_backup_restore).toBeTruthy();
  expect(result.has_credential_revocation).toBeTruthy();
  expect(result.has_failover).toBeTruthy();
  expect(result.validates).toBeTruthy();
});
