const { execFileSync } = require("node:child_process");
const path = require("node:path");

const MIX_RUN_ACCEPTANCE_PATTERN = /\bmix\b.*\brun\b.*acceptance\/scripts\//;

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
  const lingering = findLingeringMixRunChildren({ rootPid, deps });

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

function runAcceptanceScript(scriptPath, { timeoutMs = 120_000, env = {} } = {}) {
  const repoRoot = path.resolve(__dirname, "..", "..", "..");

  enforceNoLingeringMixRunChildren({ context: `before ${scriptPath}` });

  let output;

  try {
    output = execFileSync("mix", ["run", scriptPath], {
      cwd: repoRoot,
      env: { ...process.env, ASDF_ELIXIR_VERSION: "1.19.4-otp-28", ...env },
      timeout: timeoutMs,
      killSignal: "SIGKILL"
    }).toString();
  } finally {
    enforceNoLingeringMixRunChildren({ context: `after ${scriptPath}` });
  }

  return {
    output,
    result: parseResultJson(output, scriptPath)
  };
}

module.exports = {
  runAcceptanceScript,
  enforceNoLingeringMixRunChildren,
  __private: {
    parseProcessRow,
    descendantPids,
    findLingeringMixRunChildren,
    cleanupLingeringMixRunChildren,
    parseResultJson
  }
};
