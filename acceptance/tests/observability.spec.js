const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");
const path = require("node:path");

test("mom exports pipeline observability metrics and emits SLO breaches", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/observability_prometheus_acceptance.exs"],
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

  expect(result.has_enqueued_metric).toBeTruthy();
  expect(result.has_dropped_metric).toBeTruthy();
  expect(result.has_failed_metric).toBeTruthy();
  expect(result.has_drop_rate_metric).toBeTruthy();
  expect(result.has_failure_rate_metric).toBeTruthy();
  expect(result.has_latency_metric).toBeTruthy();
  expect(result.saw_queue_depth_breach).toBeTruthy();
  expect(result.saw_drop_rate_breach).toBeTruthy();
  expect(result.saw_failure_rate_breach).toBeTruthy();
  expect(result.saw_latency_breach).toBeTruthy();
  expect(result.snapshot_drop_rate).toBe(0.5);
  expect(result.snapshot_failure_rate).toBe(1.0);
});
