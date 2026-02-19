const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");
const path = require("node:path");

test("pipeline enforces per-repo quotas and fair tenant dispatch", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/pipeline_multi_tenant_acceptance.exs"],
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

  expect(result.enqueued_a1).toBe("ok");
  expect(result.enqueued_a2).toBe("ok");
  expect(result.enqueued_b1).toBe("ok");
  expect(result.quota_drop).toEqual(["dropped", "tenant_quota"]);
  expect(result.start_order).toEqual([1, 3, 2]);
  expect(result.final_queue_depth).toBe(0);
  expect(result.final_completed_count).toBe(3);
  expect(result.final_dropped_count).toBe(1);
});
