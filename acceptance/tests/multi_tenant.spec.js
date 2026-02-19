const { test, expect } = require("@playwright/test");
const { runAcceptanceScript } = require("./helpers/mix_runner");

test("pipeline enforces per-repo quotas and fair tenant dispatch", async () => {
  const { result } = runAcceptanceScript("acceptance/scripts/pipeline_multi_tenant_acceptance.exs");

  expect(result.enqueued_a1).toBe("ok");
  expect(result.enqueued_a2).toBe("ok");
  expect(result.enqueued_b1).toBe("ok");
  expect(result.quota_drop).toEqual(["dropped", "tenant_quota"]);
  expect(result.start_order).toEqual([1, 3, 2]);
  expect(result.final_queue_depth).toBe(0);
  expect(result.final_completed_count).toBe(3);
  expect(result.final_dropped_count).toBe(1);
});
