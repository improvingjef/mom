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

test("incident-to-PR classifier marks each stop point failure", async () => {
  const { result } = runAcceptanceScript(
    "acceptance/scripts/incident_to_pr_failure_classification_acceptance.exs"
  );

  expect(result.detect.failure_stop_point).toBe("detect");
  expect(result.detect.stop_point_classification.detect).toBe("failed");

  expect(result.patch_apply.failure_stop_point).toBe("patch_apply");
  expect(result.patch_apply.stop_point_classification.patch_apply).toBe("failed");

  expect(result.tests.failure_stop_point).toBe("tests");
  expect(result.tests.stop_point_classification.tests).toBe("failed");

  expect(result.push.failure_stop_point).toBe("push");
  expect(result.push.stop_point_classification.push).toBe("failed");

  expect(result.pr_create.failure_stop_point).toBe("pr_create");
  expect(result.pr_create.stop_point_classification.pr_create).toBe("failed");
});

test("incident-to-PR persists immutable stop-point summary artifact per run", async () => {
  const { result } = runAcceptanceScript(
    "acceptance/scripts/incident_to_pr_summary_artifact_acceptance.exs"
  );

  expect(result.persisted).toBeTruthy();
  expect(result.immutable).toBeTruthy();
  expect(result.payload.run_id).toBe("acceptance-run-42");
  expect(result.payload.signal.failure_stop_point).toBe("tests");
  expect(result.payload.signal.stop_point_classification.tests).toBe("failed");
});
