const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");
const path = require("node:path");

test("pipeline ingests incidents and applies overflow policy", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/pipeline_acceptance.exs"],
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

  expect(result.first).toBe("ok");
  expect(result.second).toBe("ok");
  expect(result.overflow).toEqual(["dropped", "oldest"]);
  expect(result.kept_first).toEqual(["diagnostics_event", { run_queue: 1 }, []]);
  expect(result.kept_second).toEqual(["error_event", { id: 3 }]);
  expect(result.queue_depth).toBe(0);
  expect(result.dropped_count).toBe(1);
});
