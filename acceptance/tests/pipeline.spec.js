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

test("pipeline enforces max concurrency while dispatching workers", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/pipeline_dispatch_acceptance.exs"],
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

  expect(result.started_initial_count).toBe(2);
  expect(result.third_started_early).toBeFalsy();
  expect(result.third_started_after_release_id).toBe(3);
  expect(result.active_workers).toBe(0);
  expect(result.completed_count).toBe(3);
  expect(result.queue_depth).toBe(0);
});

test("mom CLI parses pipeline concurrency flags", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_config_acceptance.exs"],
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

  expect(result.mode).toBe("inproc");
  expect(result.max_concurrency).toBe(7);
  expect(result.queue_max_size).toBe(280);
  expect(result.job_timeout_ms).toBe(15000);
  expect(result.overflow_policy).toBe("drop_oldest");
});

test("runner routes logs and diagnostics through pipeline workers", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/runner_pipeline_acceptance.exs"],
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

  expect(result.saw_error_event).toBeTruthy();
  expect(result.saw_diagnostics_event).toBeTruthy();
});

test("pipeline cancels timed out jobs and continues queued work", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/pipeline_timeout_acceptance.exs"],
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

  expect(result.slow_started).toBeTruthy();
  expect(result.fast_started_early).toBeFalsy();
  expect(result.fast_started).toBeTruthy();
  expect(result.active_workers).toBe(0);
  expect(result.completed_count).toBe(2);
  expect(result.queue_depth).toBe(0);
});

test("pipeline emits telemetry lifecycle events with queue visibility metadata", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/pipeline_telemetry_acceptance.exs"],
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

  expect(result.saw_enqueued).toBeTruthy();
  expect(result.saw_dropped).toBeTruthy();
  expect(result.saw_started).toBeTruthy();
  expect(result.saw_completed).toBeTruthy();
  expect(result.saw_failed).toBeTruthy();
  expect(result.event_has_fields).toBeTruthy();
  expect(result.failed_count).toBe(1);
});

test("pipeline drops duplicate in-flight incidents and allows retry after completion", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/pipeline_inflight_acceptance.exs"],
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
  expect(result.started_id).toBe(41);
  expect(result.duplicate).toEqual(["dropped", "inflight"]);
  expect(result.dropped_before_release).toBe(1);
  expect(result.queue_depth_before_release).toBe(0);
  expect(result.active_before_release).toBe(1);
  expect(result.after_release_completed).toBe(1);
  expect(result.after_completion).toBe("ok");
  expect(result.restart_id).toBe(41);
  expect(result.final_completed).toBe(2);
  expect(result.final_failed).toBe(0);
});

test("mom CLI enforces allowed github repo allowlist", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_allowlist_acceptance.exs"],
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

  expect(result.allowed_repo).toBe("acme/mom");
  expect(result.allowed_list).toEqual(["acme/mom", "acme/other"]);
  expect(result.blocked_result).toEqual(["error", "github_repo is not allowed"]);
  expect(result.saw_disallowed_repo_alert).toBeTruthy();
  expect(result.disallowed_alert_repo).toBe("evil/repo");
});

test("mom CLI enforces egress host allowlist for API providers", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_egress_policy_acceptance.exs"],
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

  expect(result.allowed_egress_hosts).toEqual(["api.github.com", "api.openai.com"]);
  expect(result.blocked_result).toEqual([
    "error",
    "allowed_egress_hosts is missing required host api.openai.com"
  ]);
});

test("mom CLI defaults codex to yolo exec profile", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_codex_profile_acceptance.exs"],
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

  expect(result.default_provider).toBe("codex");
  expect(result.default_llm_cmd).toBe("codex --yolo exec");
  expect(result.override_llm_cmd).toBe("codex --profile staging exec");
});

test("mom CLI applies branch naming policy to generated branches", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_branch_policy_acceptance.exs"],
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

  expect(result.branch_name_prefix).toBe("mom/incidents");
  expect(result.prefix_matches).toBeTruthy();
  expect(result.generated_branch.startsWith("mom/incidents-")).toBeTruthy();
  expect(result.invalid_result).toEqual([
    "error",
    "branch_name_prefix is not a valid git branch prefix"
  ]);
});

test("mom CLI enforces isolated git worktree for mutation workdir", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_workdir_isolation_acceptance.exs"],
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

  expect(result.invalid).toEqual([
    "error",
    "workdir must reference an isolated git worktree"
  ]);
  expect(result.valid_workdir).toBeTruthy();
  expect(result.valid_result).toBe("ok");
});

test("mom CLI enforces machine actor allowlist for GitHub credentials", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_actor_allowlist_acceptance.exs"],
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

  expect(result.allowed_actor_id).toBe("mom-bot");
  expect(result.allowed_actor_ids).toEqual(["mom-bot", "mom-staging"]);
  expect(result.blocked_result).toEqual(["error", "actor_id is not allowed"]);
  expect(result.missing_allowlist_result).toEqual([
    "error",
    "allowed_actor_ids must be set when github_token is configured"
  ]);
});

test("mom CLI rejects non-machine actor ids for GitHub credentials", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_machine_identity_acceptance.exs"],
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

  expect(result.machine_actor).toBe("mom-app[bot]");
  expect(result.human_actor_result).toEqual([
    "error",
    "actor_id must be a dedicated machine identity"
  ]);
});

test("mom enforces PR-only workflow for protected branches", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_pr_only_acceptance.exs"],
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

  expect(result.protected_base_branch).toBe("main");
  expect(result.protected_branches).toEqual(["main", "release"]);
  expect(result.protected_merge_result).toBe("ok");
  expect(result.blocked_event_base_branch).toBe("main");
  expect(result.unprotected_base_branch).toBe("dev");
  expect(result.unprotected_merge_result).toBe("ok");
  expect(result.merged_pr_number).toBe(11);
});

test("mom logs codex invocation start and outcome", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/llm_codex_logging_acceptance.exs"],
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

  expect(result.saw_start_success).toBeTruthy();
  expect(result.saw_completed_success).toBeTruthy();
  expect(result.saw_start_failure).toBeTruthy();
  expect(result.saw_completed_failure).toBeTruthy();
});

test("mom enforces env-only secret injection and redacts sensitive audit logs", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/mom_cli_secret_handling_acceptance.exs"],
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

  expect(result.github_token_from_env).toBe("env-github-token");
  expect(result.llm_api_key_from_env).toBe("env-llm-key");
  expect(result.github_token_flag_result).toEqual([
    "error",
    "github_token must be provided via MOM_GITHUB_TOKEN environment variable"
  ]);
  expect(result.llm_api_key_flag_result).toEqual([
    "error",
    "llm_api_key must be provided via MOM_LLM_API_KEY environment variable"
  ]);
  expect(result.token_redacted).toBeTruthy();
  expect(result.authorization_redacted).toBeTruthy();
  expect(result.cookie_redacted).toBeTruthy();
  expect(result.leaked_github_token).toBeFalsy();
  expect(result.leaked_authorization).toBeFalsy();
  expect(result.leaked_cookie).toBeFalsy();
});

test("runner handles burst mixed events and continues after an isolated worker failure", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/runner_burst_acceptance.exs"],
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

  expect(result.mixed_types_seen).toBeTruthy();
  expect(result.all_error_events_processed).toBeTruthy();
  expect(result.diagnostics_processed).toBeGreaterThan(0);
  expect(result.runner_alive_after_burst).toBeTruthy();
});

test("mom emits structured git and GitHub audit events", async () => {
  const repoRoot = path.resolve(__dirname, "..", "..");
  const output = execFileSync(
    "mix",
    ["run", "acceptance/scripts/github_audit_acceptance.exs"],
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

  expect(result.saw_branch_event).toBeTruthy();
  expect(result.saw_issue_event).toBeTruthy();
  expect(result.saw_pr_event).toBeTruthy();
  expect(result.saw_merge_attempt_event).toBeTruthy();
  expect(result.branch_event_fields).toBeTruthy();
  expect(result.issue_event_fields).toBeTruthy();
  expect(result.pr_event_fields).toBeTruthy();
  expect(result.merge_attempt_fields).toBeTruthy();
  expect(result.branch.startsWith("mom/audit-")).toBeTruthy();
  expect(result.issue_number).toBe(7);
  expect(result.pr_number).toBe(9);
});
