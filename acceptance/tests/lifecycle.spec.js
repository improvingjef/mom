const { test, expect } = require("@playwright/test");
const {
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
