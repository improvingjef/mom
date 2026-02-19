const { test, expect } = require("@playwright/test");
const {
  enforceNoLingeringMixRunChildren
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
