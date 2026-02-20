const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const crypto = require("node:crypto");
const path = require("node:path");

const MIX_RUN_ACCEPTANCE_PATTERN = /\bmix\b.*\brun\b.*acceptance\/scripts\//;
const TRUTHY_VALUES = new Set(["1", "true", "yes", "on"]);
const MONITOR_ATTACH_RACE_MARKERS = [
  "missing telemetry failed pipeline event",
  "did not terminate",
  "no process",
  "timeout",
  "etimedout"
];
const DEFAULT_ACCEPTANCE_TIMEOUT_MS = 120_000;
const RUNNER_BURST_SCRIPT_SUFFIX = "acceptance/scripts/runner_burst_acceptance.exs";
const DEFAULT_RUNNER_BURST_TIMEOUT_FLOOR_MS = 120_000;
const DEFAULT_RUNNER_BURST_TIMEOUT_STEP_MS = 30_000;
const DEFAULT_RUNNER_BURST_TIMEOUT_WORKER_STEP_MS = 5_000;
const DEFAULT_RUNNER_BURST_TIMEOUT_CAP_MS = 300_000;
const DEFAULT_RUNNER_BURST_BACKOFF_BASE_MS = 250;
const DEFAULT_RUNNER_BURST_BACKOFF_STEP_MS = 500;
const DEFAULT_RUNNER_BURST_BACKOFF_WORKER_STEP_MS = 50;
const DEFAULT_RUNNER_BURST_BACKOFF_CAP_MS = 5_000;
const DEFAULT_RETRY_BUDGET = 1;
const DEFAULT_POST_SUITE_SHUTDOWN_TIMEOUT_MS = 2000;

function parseProcessRow(line) {
  const trimmed = line.trim();
  if (!trimmed) {
    return null;
  }

  const match = trimmed.match(/^(\d+)\s+(\d+)\s+(.+)$/);
  if (!match) {
    return null;
  }

  const pid = Number.parseInt(match[1], 10);
  const ppid = Number.parseInt(match[2], 10);
  const command = match[3];

  if (Number.isNaN(pid) || Number.isNaN(ppid) || !command) {
    return null;
  }

  return { pid, ppid, command };
}

function defaultListProcesses() {
  const output = execFileSync("ps", ["-axo", "pid=,ppid=,command="], {
    encoding: "utf8"
  });

  return output
    .split("\n")
    .map(parseProcessRow)
    .filter(Boolean);
}

function descendantPids(processes, rootPid) {
  const childrenByParent = new Map();

  for (const process of processes) {
    const children = childrenByParent.get(process.ppid) || [];
    children.push(process.pid);
    childrenByParent.set(process.ppid, children);
  }

  const descendants = [];
  const queue = [...(childrenByParent.get(rootPid) || [])];

  while (queue.length > 0) {
    const pid = queue.shift();
    descendants.push(pid);

    for (const childPid of childrenByParent.get(pid) || []) {
      queue.push(childPid);
    }
  }

  return descendants;
}

function findLingeringMixRunChildren({ rootPid = process.pid, deps = {} } = {}) {
  const listProcesses = deps.listProcesses || defaultListProcesses;
  const processes = listProcesses();
  const descendants = new Set(descendantPids(processes, rootPid));

  return processes.filter(
    (proc) => descendants.has(proc.pid) && MIX_RUN_ACCEPTANCE_PATTERN.test(proc.command)
  );
}

function findLingeringMixRunChildrenStable({
  rootPid = process.pid,
  samples = 2,
  deps = {}
} = {}) {
  const count = Math.max(1, samples || 1);
  const sleep = deps.sleepMs || sleepMs;
  const childrenByPid = new Map();

  for (let index = 0; index < count; index += 1) {
    for (const child of findLingeringMixRunChildren({ rootPid, deps })) {
      childrenByPid.set(child.pid, child);
    }

    if (index < count - 1) {
      sleep(10);
    }
  }

  return Array.from(childrenByPid.values());
}

function sleepMs(milliseconds) {
  const timeout = Math.max(0, milliseconds || 0);
  const buffer = new SharedArrayBuffer(4);
  const signal = new Int32Array(buffer);
  Atomics.wait(signal, 0, 0, timeout);
}

function defaultKillProcess(pid, signal) {
  process.kill(pid, signal);
}

function cleanupLingeringMixRunChildren(children, deps = {}) {
  const killProcess = deps.killProcess || defaultKillProcess;
  const sleep = deps.sleepMs || sleepMs;
  const alive = deps.isProcessAlive || ((pid) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch (_error) {
      return false;
    }
  });

  const attempted = [];

  for (const child of children) {
    try {
      killProcess(child.pid, "SIGTERM");
      attempted.push([child.pid, "SIGTERM"]);
    } catch (_error) {
      // Ignore already-exited children.
    }
  }

  sleep(100);

  for (const child of children) {
    if (!alive(child.pid)) {
      continue;
    }

    try {
      killProcess(child.pid, "SIGKILL");
      attempted.push([child.pid, "SIGKILL"]);
    } catch (_error) {
      // Ignore already-exited children.
    }
  }

  return attempted;
}

function formatChild(child) {
  return `${child.pid}:${child.ppid}:${child.command}`;
}

function enforceNoLingeringMixRunChildren({
  context,
  rootPid = process.pid,
  deps = {}
} = {}) {
  const lingering = findLingeringMixRunChildrenStable({ rootPid, deps });

  if (lingering.length === 0) {
    return;
  }

  const cleanup = cleanupLingeringMixRunChildren(lingering, deps);
  const suffix = context ? ` (${context})` : "";

  throw new Error(
    `Lingering mix run child processes detected${suffix}: ${lingering
      .map(formatChild)
      .join(", ")}. Cleanup attempts=${JSON.stringify(cleanup)}`
  );
}

function parseResultJson(output, scriptPath) {
  const marker = output
    .split("\n")
    .find((line) => line.startsWith("RESULT_JSON:"));

  if (!marker) {
    throw new Error(`Missing RESULT_JSON marker for ${scriptPath}`);
  }

  return JSON.parse(marker.replace("RESULT_JSON:", ""));
}

function asTruthyFlag(value) {
  if (typeof value !== "string") {
    return false;
  }

  return TRUTHY_VALUES.has(value.trim().toLowerCase());
}

function parseRetryBudget(value) {
  if (typeof value !== "string") {
    return DEFAULT_RETRY_BUDGET;
  }

  const parsed = Number.parseInt(value.trim(), 10);
  if (Number.isNaN(parsed) || parsed < 0) {
    return DEFAULT_RETRY_BUDGET;
  }

  return parsed;
}

function parsePostSuiteShutdownTimeoutMs(value) {
  if (typeof value !== "string") {
    return DEFAULT_POST_SUITE_SHUTDOWN_TIMEOUT_MS;
  }

  const parsed = Number.parseInt(value.trim(), 10);
  if (Number.isNaN(parsed) || parsed < 0) {
    return DEFAULT_POST_SUITE_SHUTDOWN_TIMEOUT_MS;
  }

  return parsed;
}

function parseNonNegInt(value, defaultValue) {
  if (typeof value !== "string") {
    return defaultValue;
  }

  const parsed = Number.parseInt(value.trim(), 10);
  if (Number.isNaN(parsed) || parsed < 0) {
    return defaultValue;
  }

  return parsed;
}

function isRunnerBurstScript(scriptPath) {
  return scriptPath.endsWith(RUNNER_BURST_SCRIPT_SUFFIX);
}

function resolveAcceptanceTimeoutMs({
  scriptPath,
  attempt,
  baseTimeoutMs = DEFAULT_ACCEPTANCE_TIMEOUT_MS,
  env = process.env
}) {
  const normalizedAttempt = Math.max(1, attempt || 1);

  if (!isRunnerBurstScript(scriptPath)) {
    return baseTimeoutMs;
  }

  const workerIndex = parseNonNegInt(env.TEST_WORKER_INDEX, 0);
  const timeoutFloorMs = parseNonNegInt(
    env.MOM_ACCEPTANCE_RUNNER_BURST_TIMEOUT_FLOOR_MS,
    DEFAULT_RUNNER_BURST_TIMEOUT_FLOOR_MS
  );
  const timeoutStepMs = parseNonNegInt(
    env.MOM_ACCEPTANCE_RUNNER_BURST_TIMEOUT_STEP_MS,
    DEFAULT_RUNNER_BURST_TIMEOUT_STEP_MS
  );
  const timeoutWorkerStepMs = parseNonNegInt(
    env.MOM_ACCEPTANCE_RUNNER_BURST_TIMEOUT_WORKER_STEP_MS,
    DEFAULT_RUNNER_BURST_TIMEOUT_WORKER_STEP_MS
  );
  const timeoutCapMs = parseNonNegInt(
    env.MOM_ACCEPTANCE_RUNNER_BURST_TIMEOUT_CAP_MS,
    DEFAULT_RUNNER_BURST_TIMEOUT_CAP_MS
  );

  const timeoutMs =
    Math.max(baseTimeoutMs, timeoutFloorMs) +
    (normalizedAttempt - 1) * timeoutStepMs +
    workerIndex * timeoutWorkerStepMs;

  return Math.min(timeoutMs, timeoutCapMs);
}

function resolveRetryBackoffMs({ scriptPath, attempt, env = process.env }) {
  const normalizedAttempt = Math.max(1, attempt || 1);

  if (!isRunnerBurstScript(scriptPath)) {
    return 0;
  }

  const workerIndex = parseNonNegInt(env.TEST_WORKER_INDEX, 0);
  const backoffBaseMs = parseNonNegInt(
    env.MOM_ACCEPTANCE_RUNNER_BURST_BACKOFF_BASE_MS,
    DEFAULT_RUNNER_BURST_BACKOFF_BASE_MS
  );
  const backoffStepMs = parseNonNegInt(
    env.MOM_ACCEPTANCE_RUNNER_BURST_BACKOFF_STEP_MS,
    DEFAULT_RUNNER_BURST_BACKOFF_STEP_MS
  );
  const backoffWorkerStepMs = parseNonNegInt(
    env.MOM_ACCEPTANCE_RUNNER_BURST_BACKOFF_WORKER_STEP_MS,
    DEFAULT_RUNNER_BURST_BACKOFF_WORKER_STEP_MS
  );
  const backoffCapMs = parseNonNegInt(
    env.MOM_ACCEPTANCE_RUNNER_BURST_BACKOFF_CAP_MS,
    DEFAULT_RUNNER_BURST_BACKOFF_CAP_MS
  );

  const backoffMs =
    backoffBaseMs +
    (normalizedAttempt - 1) * backoffStepMs +
    workerIndex * backoffWorkerStepMs;

  return Math.min(backoffMs, backoffCapMs);
}

function classifyFailure(error) {
  const body = extractErrorBody(error);
  const downcased = body.toLowerCase();

  if (MONITOR_ATTACH_RACE_MARKERS.some((marker) => downcased.includes(marker))) {
    return "monitor_attach_race";
  }

  return "non_retryable";
}

function extractErrorBody(error) {
  if (!error) {
    return "";
  }

  const candidates = [
    error.stderr,
    error.stdout,
    error.message,
    error.code,
    error.errno,
    error.signal,
    error.stack,
    error
  ];
  const parts = [];

  for (const candidate of candidates) {
    if (candidate == null) {
      continue;
    }

    const text = String(candidate).trim();
    if (text.length > 0) {
      parts.push(text);
    }
  }

  return parts.join("\n");
}

function shouldRetry({ attempt, retryBudget, classification }) {
  return classification === "monitor_attach_race" && attempt <= retryBudget;
}

function findOrphanedLingeringMixRunChildren({ deps = {} } = {}) {
  const listProcesses = deps.listProcesses || defaultListProcesses;
  const processes = listProcesses();
  const knownPids = new Set(processes.map((proc) => proc.pid));

  return processes.filter(
    (proc) =>
      MIX_RUN_ACCEPTANCE_PATTERN.test(proc.command) && proc.ppid > 1 && !knownPids.has(proc.ppid)
  );
}

function deterministicAttemptId({ scriptPath, attempt, env }) {
  const runId = sanitizeSegment(env.MOM_ACCEPTANCE_RUN_ID || `pw${process.ppid || process.pid}`);
  const worker = sanitizeSegment(env.TEST_WORKER_INDEX || "0");
  const digest = crypto
    .createHash("sha1")
    .update(`${scriptPath}|${runId}|${worker}|${attempt}`)
    .digest("hex")
    .slice(0, 12);
  return `${runId}-${worker}-a${attempt}-${digest}`;
}

function writeConcurrencyReport(reportPath, entry, deps = {}) {
  if (!reportPath) {
    return;
  }

  const readFile = deps.readFileSync || fs.readFileSync;
  const writeFile = deps.writeFileSync || fs.writeFileSync;
  const mkdirP = deps.mkdirSync || fs.mkdirSync;
  const dirname = path.dirname(reportPath);
  mkdirP(dirname, { recursive: true });

  let current = [];

  try {
    const body = readFile(reportPath, "utf8");
    const parsed = JSON.parse(body);
    current = Array.isArray(parsed) ? parsed : [];
  } catch (_error) {
    current = [];
  }

  current.push(entry);
  current.sort((left, right) => left.attempt_id.localeCompare(right.attempt_id));
  writeFile(reportPath, `${JSON.stringify(current, null, 2)}\n`, "utf8");
}

function resolveBuildIsolationMode(env = process.env) {
  if (asTruthyFlag(env.MOM_ACCEPTANCE_SERIALIZED)) {
    return "serialized";
  }

  const requestedMode = (env.MOM_ACCEPTANCE_BUILD_MODE || "").trim().toLowerCase();
  if (requestedMode === "serialized") {
    return "serialized";
  }

  return "worker-isolated";
}

function sanitizeSegment(value) {
  return (value || "").trim().replace(/[^a-zA-Z0-9_-]/g, "_") || "default";
}

function resolveBuildArtifactPath({
  env = process.env,
  workerIndex = env.TEST_WORKER_INDEX || "0",
  parentPid = process.ppid || process.pid
} = {}) {
  const mode = resolveBuildIsolationMode(env);
  const runId = sanitizeSegment(env.MOM_ACCEPTANCE_RUN_ID || `pw${parentPid}`);

  if (mode === "serialized") {
    return `_build_acceptance_serialized_${runId}`;
  }

  const worker = sanitizeSegment(String(workerIndex));
  return `_build_acceptance_worker_${runId}_${worker}`;
}

function withBuildIsolationEnv(baseEnv, options = {}) {
  if (baseEnv.MIX_BUILD_PATH) {
    return baseEnv;
  }

  return {
    ...baseEnv,
    MIX_BUILD_PATH: resolveBuildArtifactPath(options)
  };
}

function collectPostSuiteLingeringChildren({ rootPid = process.pid, deps = {} } = {}) {
  const childrenByPid = new Map();

  for (const child of findLingeringMixRunChildrenStable({ rootPid, deps })) {
    childrenByPid.set(child.pid, child);
  }

  for (const child of findOrphanedLingeringMixRunChildren({ deps })) {
    childrenByPid.set(child.pid, child);
  }

  return Array.from(childrenByPid.values());
}

function runPostSuiteTerminationGuardrails({
  rootPid = process.pid,
  timeoutMs = parsePostSuiteShutdownTimeoutMs(
    process.env.MOM_ACCEPTANCE_POST_SUITE_SHUTDOWN_TIMEOUT_MS
  ),
  deps = {}
} = {}) {
  const sleep = deps.sleepMs || sleepMs;
  const nowMs = deps.nowMs || Date.now;
  const budgetMs = Math.max(0, timeoutMs || 0);
  const initialLingering = collectPostSuiteLingeringChildren({ rootPid, deps });

  if (initialLingering.length === 0) {
    return { status: "clean", lingering: [], forced: false };
  }

  cleanupLingeringMixRunChildren(initialLingering, deps);

  const deadline = nowMs() + budgetMs;
  let remaining = collectPostSuiteLingeringChildren({ rootPid, deps });

  while (remaining.length > 0 && nowMs() < deadline) {
    sleep(25);
    remaining = collectPostSuiteLingeringChildren({ rootPid, deps });
  }

  if (remaining.length === 0) {
    return { status: "cleaned", lingering: initialLingering, forced: false };
  }

  const finalCleanup = cleanupLingeringMixRunChildren(remaining, deps);
  throw new Error(
    `Post-suite acceptance termination guardrail forced shutdown: timeout_ms=${budgetMs} lingering=${remaining
      .map(formatChild)
      .join(", ")} cleanup_attempts=${JSON.stringify(finalCleanup)}`
  );
}

function enforcePostSuiteTerminationGuardrails(options = {}) {
  return runPostSuiteTerminationGuardrails(options);
}

function runAcceptanceScript(scriptPath, { timeoutMs = 120_000, env = {}, deps = {} } = {}) {
  const repoRoot = path.resolve(__dirname, "..", "..", "..");
  const runnerExecFileSync = deps.execFileSync || execFileSync;
  const mergedEnv = { ...process.env, ...env };
  const retryBudget = parseRetryBudget(mergedEnv.MOM_ACCEPTANCE_RETRY_BUDGET);
  const failOnFlaky = asTruthyFlag(mergedEnv.MOM_ACCEPTANCE_FAIL_ON_FLAKY);
  const reportPath = mergedEnv.MOM_ACCEPTANCE_CONCURRENCY_REPORT_PATH;
  let attempt = 0;
  let retried = false;
  let lastError;

  while (attempt <= retryBudget) {
    attempt += 1;
    const attemptId = deterministicAttemptId({ scriptPath, attempt, env: mergedEnv });

    enforceNoLingeringMixRunChildren({
      context: `before ${scriptPath} attempt ${attempt}`,
      deps
    });

    let output;

    try {
      const timeoutBudgetMs = resolveAcceptanceTimeoutMs({
        scriptPath,
        attempt,
        baseTimeoutMs: timeoutMs,
        env: mergedEnv
      });

      const baseEnv = {
        ...mergedEnv,
        ASDF_ELIXIR_VERSION: "1.19.4-otp-28",
        MOM_ACCEPTANCE_ATTEMPT_ID: attemptId
      };

      output = runnerExecFileSync("mix", ["run", scriptPath], {
        cwd: repoRoot,
        env: withBuildIsolationEnv(baseEnv),
        timeout: timeoutBudgetMs,
        killSignal: "SIGKILL"
      }).toString();

      const result = parseResultJson(output, scriptPath);
      const flaky = retried;

      writeConcurrencyReport(
        reportPath,
        {
          attempt_id: attemptId,
          script_path: scriptPath,
          attempt,
          retry_budget: retryBudget,
          status: "passed",
          flaky,
          timeout_budget_ms: timeoutBudgetMs
        },
        deps
      );

      if (flaky && failOnFlaky) {
        throw new Error(
          `Flaky acceptance test detected for ${scriptPath}: passed on attempt ${attempt} with retry budget ${retryBudget}`
        );
      }

      return { output, result };
    } catch (error) {
      lastError = error;
      const classification = classifyFailure(error);
      const retrying = shouldRetry({ attempt, retryBudget, classification });

      writeConcurrencyReport(
        reportPath,
        {
          attempt_id: attemptId,
          script_path: scriptPath,
          attempt,
          retry_budget: retryBudget,
          status: retrying ? "retrying" : "failed",
          classification,
          timeout_budget_ms: resolveAcceptanceTimeoutMs({
            scriptPath,
            attempt,
            baseTimeoutMs: timeoutMs,
            env: mergedEnv
          })
        },
        deps
      );

      if (retrying) {
        retried = true;
        const backoffMs = resolveRetryBackoffMs({
          scriptPath,
          attempt,
          env: mergedEnv
        });

        if (backoffMs > 0) {
          (deps.sleepMs || sleepMs)(backoffMs);
        }
      } else {
        const reason =
          classification === "monitor_attach_race" && attempt > retryBudget
            ? `Retry budget exhausted for ${scriptPath}: attempts=${attempt} budget=${retryBudget}`
            : `Acceptance script failed for ${scriptPath}: ${error.message || String(error)}`;

        throw new Error(reason);
      }
    } finally {
      enforceNoLingeringMixRunChildren({
        context: `after ${scriptPath} attempt ${attempt}`,
        deps
      });
    }
  }

  throw lastError;
}

module.exports = {
  runAcceptanceScript,
  enforceNoLingeringMixRunChildren,
  enforcePostSuiteTerminationGuardrails,
  __private: {
    parseProcessRow,
    descendantPids,
    findLingeringMixRunChildren,
    cleanupLingeringMixRunChildren,
    findLingeringMixRunChildrenStable,
    findOrphanedLingeringMixRunChildren,
    parseResultJson,
    parseRetryBudget,
    parsePostSuiteShutdownTimeoutMs,
    parseNonNegInt,
    resolveAcceptanceTimeoutMs,
    resolveRetryBackoffMs,
    classifyFailure,
    shouldRetry,
    deterministicAttemptId,
    writeConcurrencyReport,
    resolveBuildIsolationMode,
    resolveBuildArtifactPath,
    withBuildIsolationEnv,
    runPostSuiteTerminationGuardrails
  }
};
