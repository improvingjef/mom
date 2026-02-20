const { test, expect } = require("@playwright/test");
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");
const {
  runAcceptanceScript,
  enforceNoLingeringMixRunChildren,
  __private
} = require("./helpers/mix_runner");

test("acceptance runner fails fast and cleans lingering mix run children", async () => {
  const killed = [];

  const deps = {
    listProcesses: () => [
      { pid: 100, ppid: 1, command: "node worker" },
      {
        pid: 101,
        ppid: 100,
        command: "mix run acceptance/scripts/pipeline_acceptance.exs"
      },
      { pid: 102, ppid: 101, command: "beam.smp" }
    ],
    killProcess: (pid, signal) => {
      killed.push([pid, signal]);
      return true;
    },
    sleepMs: () => {}
  };

  expect(() =>
    enforceNoLingeringMixRunChildren({
      context: "before test",
      rootPid: 100,
      deps
    })
  ).toThrow(/Lingering mix run child processes detected/);

  expect(killed).toContainEqual([101, "SIGTERM"]);
});

test("acceptance runner isolates build artifacts per worker by default", async () => {
  const env = {
    TEST_WORKER_INDEX: "3",
    MOM_ACCEPTANCE_RUN_ID: "ci/run#42"
  };

  expect(__private.resolveBuildIsolationMode(env)).toBe("worker-isolated");
  expect(__private.resolveBuildArtifactPath({ env, parentPid: 999 })).toBe(
    "_build_acceptance_worker_ci_run_42_3"
  );

  expect(__private.withBuildIsolationEnv({ ...env }, { env, parentPid: 999 })).toMatchObject({
    MIX_BUILD_PATH: "_build_acceptance_worker_ci_run_42_3"
  });
});

test("acceptance runner supports serialized build mode", async () => {
  const env = {
    TEST_WORKER_INDEX: "7",
    MOM_ACCEPTANCE_SERIALIZED: "true",
    MOM_ACCEPTANCE_RUN_ID: "nightly run"
  };

  expect(__private.resolveBuildIsolationMode(env)).toBe("serialized");
  expect(__private.resolveBuildArtifactPath({ env, parentPid: 777 })).toBe(
    "_build_acceptance_serialized_nightly_run"
  );
});

test("acceptance runner retries monitor-attach-race failures within retry budget and records flake metadata", async () => {
  const reportPath = path.join(
    os.tmpdir(),
    `mom-acceptance-concurrency-${Date.now()}-${Math.random().toString(16).slice(2)}.json`
  );

  let calls = 0;
  const deps = {
    execFileSync: () => {
      calls += 1;

      if (calls === 1) {
        const error = new Error("missing telemetry failed pipeline event");
        error.stderr = "missing telemetry failed pipeline event";
        throw error;
      }

      return Buffer.from('RESULT_JSON:{"ok":true}\n');
    },
    listProcesses: () => [],
    sleepMs: () => {}
  };

  const { result } = runAcceptanceScript("acceptance/scripts/fake_acceptance.exs", {
    env: {
      MOM_ACCEPTANCE_RETRY_BUDGET: "1",
      MOM_ACCEPTANCE_FAIL_ON_FLAKY: "false",
      MOM_ACCEPTANCE_CONCURRENCY_REPORT_PATH: reportPath,
      MOM_ACCEPTANCE_RUN_ID: "ci-acceptance"
    },
    deps
  });

  expect(result.ok).toBeTruthy();
  expect(calls).toBe(2);

  const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
  expect(report).toHaveLength(2);
  expect(report[0].status).toBe("retrying");
  expect(report[0].classification).toBe("monitor_attach_race");
  expect(report[1].status).toBe("passed");
  expect(report[1].flaky).toBeTruthy();

  fs.rmSync(reportPath, { force: true });
});

test("acceptance runner enforces retry-budget exhaustion for monitor-attach races", async () => {
  const deps = {
    execFileSync: () => {
      const error = new Error("did not terminate");
      error.stderr = "did not terminate";
      throw error;
    },
    listProcesses: () => [],
    sleepMs: () => {}
  };

  expect(() =>
    runAcceptanceScript("acceptance/scripts/fake_acceptance.exs", {
      env: { MOM_ACCEPTANCE_RETRY_BUDGET: "1" },
      deps
    })
  ).toThrow(/Retry budget exhausted/);
});

test("acceptance runner parses bounded post-suite shutdown timeout policy", async () => {
  expect(__private.parsePostSuiteShutdownTimeoutMs("2500")).toBe(2500);
  expect(__private.parsePostSuiteShutdownTimeoutMs("invalid")).toBe(2000);
});

test("acceptance runner post-suite guardrail is a no-op when no lingering acceptance processes exist", async () => {
  const result = __private.runPostSuiteTerminationGuardrails({
    rootPid: 100,
    timeoutMs: 25,
    deps: {
      listProcesses: () => [{ pid: 100, ppid: 1, command: "node playwright" }],
      sleepMs: () => {},
      nowMs: (() => {
        let tick = 0;
        return () => ++tick;
      })()
    }
  });

  expect(result.status).toBe("clean");
  expect(result.lingering).toHaveLength(0);
});

test("acceptance runner post-suite guardrail forces bounded shutdown when lingering orphan survives cleanup", async () => {
  const killed = [];

  expect(() =>
    __private.runPostSuiteTerminationGuardrails({
      rootPid: 100,
      timeoutMs: 2,
      deps: {
        listProcesses: () => [
          { pid: 100, ppid: 1, command: "node playwright" },
          {
            pid: 500,
            ppid: 999,
            command: "mix run acceptance/scripts/pipeline_acceptance.exs"
          }
        ],
        killProcess: (pid, signal) => {
          killed.push([pid, signal]);
        },
        isProcessAlive: (pid) => pid === 500,
        sleepMs: () => {},
        nowMs: (() => {
          let tick = 0;
          return () => {
            tick += 5;
            return tick;
          };
        })()
      }
    })
  ).toThrow(/Post-suite acceptance termination guardrail forced shutdown/);

  expect(killed).toContainEqual([500, "SIGTERM"]);
  expect(killed).toContainEqual([500, "SIGKILL"]);
});

test("mom startup prunes stale acceptance build artifacts by retention policy", async () => {
  const { result } = runAcceptanceScript(
    "acceptance/scripts/mom_cli_build_artifact_cleanup_acceptance.exs"
  );

  expect(result.pruned_runner_burst).toBeTruthy();
  expect(result.pruned_worker_scoped).toBeTruthy();
  expect(result.kept_recent_worker_scoped).toBeTruthy();
  expect(result.kept_non_matching_directory).toBeTruthy();
});

test("mom startup enforces deterministic temp worktree lifecycle controls", async () => {
  const { result } = runAcceptanceScript(
    "acceptance/scripts/mom_cli_worktree_temp_path_lifecycle_acceptance.exs"
  );

  expect(result.pruned_stale_worktree).toBeTruthy();
  expect(result.kept_recent_worktree).toBeTruthy();
  expect(result.collision_avoided).toBeTruthy();
  expect(result.worktree_path_deterministic).toBeTruthy();
});

test("mom startup enforces temp worktree capacity guardrails and runbook coverage", async () => {
  const { result } = runAcceptanceScript(
    "acceptance/scripts/mom_cli_worktree_capacity_guardrails_acceptance.exs"
  );

  expect(result.startup_blocked).toBeTruthy();
  expect(result.observed_event_emitted).toBeTruthy();
  expect(result.alert_event_emitted).toBeTruthy();
  expect(result.blocked_event_emitted).toBeTruthy();
  expect(result.backpressure_alert_emitted).toBeTruthy();
  expect(result.backpressure_blocked_emitted).toBeTruthy();
  expect(result.saturation_runbook_present).toBeTruthy();
});

test("worker lifecycle watchdog force-cleans orphan processes and emits alerts", async () => {
  const { result } = runAcceptanceScript(
    "acceptance/scripts/mom_cli_worker_lifecycle_watchdog_acceptance.exs"
  );

  expect(result.watchdog_alert_emitted).toBeTruthy();
  expect(result.watchdog_audit_emitted).toBeTruthy();
  expect(result.orphan_force_cleaned).toBeTruthy();
});
