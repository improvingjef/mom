const { test, expect } = require("@playwright/test");
const { runAcceptanceScript } = require("./helpers/mix_runner");

test("incident-to-PR path emits an end-to-end success signal including PR creation", async () => {
  const { result } = runAcceptanceScript("acceptance/scripts/incident_to_pr_success_acceptance.exs");

  expect(result.incident_to_pr_success).toBeTruthy();
  expect(result.saw_issue_event).toBeTruthy();
  expect(result.saw_patch_event).toBeTruthy();
  expect(result.saw_tests_event).toBeTruthy();
  expect(result.saw_push_event).toBeTruthy();
  expect(result.saw_pr_event).toBeTruthy();
  expect(result.signal.missing_steps).toEqual([]);
  expect(result.signal.out_of_order_steps).toEqual([]);
  expect(result.signal.tests_status_ok).toBeTruthy();
  expect(result.signal.branch_matches).toBeTruthy();
  expect(result.signal.pr_number).toBe(12);
});
