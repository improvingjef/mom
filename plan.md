# Mom Concurrency-First Plan

## Goal
Enable Mom to safely process multiple incidents concurrently (with bounded parallelism and backpressure) before building the full Phoenix + Playwright stress harness.

## Why This First
- Current runner flow (`Mom.Runner` -> `Mom.Engine.handle_log/2`) is effectively single-threaded per runner process.
- Rapid-fire incident generation will otherwise serialize into one long queue and hide concurrency bugs.
- We need predictable behavior under burst traffic before trusting e2e stress results.

## Scope
In scope:
- Concurrent log incident triage/fix pipeline
- Concurrent diagnostics triage pipeline
- Queueing, dedupe, rate-limits, and failure isolation under load
- Telemetry and visibility for active/queued/completed jobs
- Tests and load simulation for concurrency behavior
- Cross-repo execution model and commit/test discipline for Mom-driven development workflow

Out of scope (for this phase):
- Full Phoenix app + Playwright harness
- Product/UI polish in `mom_web`
- Large refactors unrelated to concurrency safety

## Repo Topology and Delivery Discipline

### Active Repositories
- `mom` (core orchestration/runtime) - primary implementation target for this plan.
- `mom_web` (web interface) - distinct git history and release surface.
- test harness repo (new, separate) - intentionally fragile app + Playwright orchestration target.

### Working Rules
- Treat each repo as an independent unit of change; no cross-repo "hidden" dependency changes without explicit traceability.
- Commit after each completed task in the repo where the task is performed.
- Do not batch unrelated tasks into one commit.
- Keep commit messages scoped to one completed checklist item or tightly related pair.

### Test Requirements Per Task
- Every task must include normal ExUnit TDD coverage for affected Elixir behavior.
- Every task that changes end-to-end/operator behavior must include Playwright coverage in the harness repo.
- If a task is backend-only and not user/operator observable, document why Playwright is not applicable in task notes.

## Success Criteria
- Mom can process multiple incidents at once (configurable, default `max_concurrency=4`).
- No crash propagation: one failing triage job does not stop other jobs.
- Backpressure works: queue has a bounded size and explicit overflow policy.
- Dedupe/rate-limit logic still prevents noisy duplicate issue/LLM floods.
- Under burst test (e.g., 50 errors in <10s), Mom remains responsive and stable.
- Clear metrics/logging show throughput, queue depth, active workers, failures.
- Source repository access is least-privilege, isolated, auditable, and revocable.

## Architecture Changes

### 1. Introduce a Job Pipeline
- Add `Mom.Pipeline` (GenServer) as ingestion + queue coordinator.
- Inputs:
  - `{:error_event, event}`
  - `{:diagnostics_event, report, issues}`
- Queue:
  - bounded FIFO (or priority queue: errors > diagnostics)
  - queue size configurable (`queue_max_size`)
- Overflow policy (configurable):
  - `:drop_newest` (default) or `:drop_oldest`

### 2. Worker Supervision
- Add `Mom.WorkerSupervisor` (`DynamicSupervisor`) for triage workers.
- `Mom.Pipeline` dispatches jobs while `active_workers < max_concurrency`.
- Each job runs in an isolated worker/task process.
- Use monitor signals to reclaim worker slots reliably.

### 3. Preserve Existing Engine Logic
- Keep `Mom.Engine` as the unit of work executor.
- Wrap engine calls in worker modules:
  - `Mom.Workers.LogTriage`
  - `Mom.Workers.DiagnosticsTriage`
- Add per-job timeout and cancellation handling.

### 4. Config Additions
- `max_concurrency` (default 4)
- `queue_max_size` (default 200)
- `job_timeout_ms` (default 120_000)
- `overflow_policy` (`:drop_newest | :drop_oldest`)

### 5. Telemetry + Logging
- Emit telemetry events:
  - `[:mom, :pipeline, :enqueued]`
  - `[:mom, :pipeline, :dropped]`
  - `[:mom, :pipeline, :started]`
  - `[:mom, :pipeline, :completed]`
  - `[:mom, :pipeline, :failed]`
- Include queue depth, active count, job type, duration, reason.

## Concurrency Safety Considerations
- Keep `RateLimiter` ETS usage thread-safe (validate atomic behavior under concurrency).
- Ensure issue dedupe signature checks remain correct with parallel jobs.
- Add per-signature in-flight guard to avoid duplicate triage races:
  - e.g., `:ets`/`Registry` for `inflight_signatures`.
- Keep git worktree isolation per job (already aligned with current design).

## Source Repository Security Requirements

### 1. Identity and Access
- Use a dedicated machine user / GitHub App identity for Mom; never human personal credentials.
- Scope credentials to one repository (or explicit allowlist) with minimum required permissions:
  - `contents: read/write` (for branch push)
  - `pull_requests: write`
  - `issues: write`
  - no admin/org-wide scopes
- Enforce short-lived credentials where possible (GitHub App installation tokens preferred).

### 2. Branch and Merge Protection
- Never allow Mom to push to protected default branch directly.
- Require PR-only flow to protected branches.
- Disable automerge by default in production (`merge_pr=false`), with explicit opt-in.
- Require CODEOWNERS/review checks for Mom-authored PRs.

### 3. Secret Handling
- Provide credentials via environment variables or secret manager only.
- Never log raw tokens, cookies, or SSH keys.
- Keep redaction defaults mandatory for sensitive keys (`token`, `authorization`, `cookie`, etc.).
- Rotate credentials on schedule and immediately on suspected exposure.

### 4. Execution Isolation
- Use isolated worktrees only; never modify source checkout in place.
- Run Mom under a restricted OS account with minimal filesystem permissions.
- Limit outbound network egress to required endpoints (GitHub API, chosen LLM endpoint).
- Prefer container/sandbox runtime for Mom workers in higher-risk environments.

### 5. Repo Target Controls
- Add optional config allowlist:
  - `allowed_github_repos` (exact matches only)
  - startup hard-fails if target repo is not allowed.
- Add optional branch naming policy for Mom-generated branches.

### 6. Audit and Detection
- Emit structured audit logs for:
  - repo targeted
  - issue/branch/PR created
  - credential identity used (non-secret identifier)
  - merge attempts (allowed/blocked)
- Add alerting for unusual activity:
  - sudden spike in PR creation
  - repeated auth failures
  - attempts to target non-allowlisted repos.

### 7. E2E Harness Security Gate
- Before running Playwright burst tests:
  - verify private repo created
  - verify branch protection is active
  - verify least-privilege credential works
  - verify revoked credential fails safely.

## LLM Execution Profile (Test Assumption)
- Decision (for this test): Mom will run Codex CLI directly for analysis and break-fix PR work.
- Command profile:
  - `codex --yolo exec`
- Reason:
  - fastest path to validate full incident -> fix -> PR flow end-to-end.
- Guardrails that still apply during test:
  - PR-only workflow (no direct pushes to protected branch)
  - least-privilege repo credentials
  - full invocation/result logging for traceability
- Exit criteria for keeping this profile:
  - test demonstrates stable queueing/concurrency behavior
  - generated fixes/PRs are high-signal enough to continue investment

### Future Hardening Track (Post-Validation)
- Replace broad `--yolo` execution with constrained execution policy.
- Introduce explicit agent safety profiles:
  - `test_relaxed` (current): `codex --yolo exec`, full logging, PR-only git flow
  - `staging_restricted`: sandboxed runtime, writable-path limits, command allowlist
  - `production_hardened`: restricted profile + approval gates for sensitive ops
- Hardening backlog (next planning slice):
  - define command allow/deny policy for Codex-invoked tools
  - enforce filesystem write boundaries to isolated worktree paths only
  - restrict network egress to GitHub + approved model endpoints
  - add policy checks that fail closed on violations
  - add audit assertions for every agent action that mutates git state

## Implementation Steps

1. Baseline & Instrumentation
- Add temporary benchmark script to submit synthetic incidents.
- Capture baseline throughput/latency on current single-thread behavior.

2. Add Config + Validation
- Extend `Mom.Config` and mix task flags for new concurrency controls.
- Add defaults and runtime env support.

3. Build Pipeline + Worker Supervisor
- Implement `Mom.Pipeline` queue + dispatch loop.
- Implement worker supervision and job lifecycle handling.
- Wire `Mom.Runner` to enqueue events instead of direct engine call.

4. Add In-Flight Signature Guard
- Prevent duplicate concurrent work for same signature window.
- Ensure cleanup on both success and failure.

5. Telemetry + Structured Logs
- Add events and log fields for queue/worker visibility.

6. Test Coverage
- Unit tests:
  - queue capacity + overflow behavior
  - dispatch up to max concurrency
  - worker failure isolation
  - timeout handling
  - in-flight dedupe
- Integration tests:
  - burst of mixed error + diagnostics events
  - assert no runner deadlock/crash
  - assert expected issue/LLM call ceilings with rate limits

7. Load Simulation
- Add a local stress script (`mix` task) to generate N events quickly.
- Validate stability and throughput against success criteria.

8. Readiness Gate for E2E Harness
- Proceed to Phoenix + Playwright harness only after criteria are met.
- Security checklist above must pass before enabling automated PR creation.

## Risks and Mitigations
- Risk: parallel LLM/test/git operations overload local machine
  - Mitigation: conservative defaults, queue bounds, explicit timeouts
- Risk: duplicate issue/PR generation under race conditions
  - Mitigation: in-flight signature guard + existing dedupe window
- Risk: starvation of diagnostics jobs
  - Mitigation: optional weighted dispatch or reserved slot for diagnostics

## Deliverables
- Concurrency pipeline code + configuration
- Concurrency-focused test suite
- Stress script and benchmark notes
- Short runbook documenting tuning knobs and recommended defaults

## Next Phase (After This Plan Is Done)
- Build intentionally fragile Phoenix test app
- Create private GitHub repo via `gh`
- Run Mom against app repo
- Use Playwright in two modes:
  - human-paced baseline mode (default): realistic think time and navigation pacing
  - burst stress mode: rapid-fire concurrent fault triggering
- Evaluate issue/PR behavior and concurrency in realistic e2e flow

## E2E Harness Modes (Planned)

### 1. Human-Paced Baseline (Default)
- Purpose: approximate how a real user triggers failures over time.
- Characteristics:
  - short think-time delays between actions (hundreds of ms to a few seconds)
  - mostly sequential flows with occasional overlap
  - mixed route usage, form fills, and navigation backtracking
- Output focus:
  - correctness of issue creation and patch/PR quality
  - user-realistic triage latency and system stability

### 2. Burst Stress Mode
- Purpose: test queueing, backpressure, and bounded concurrency under spikes.
- Characteristics:
  - minimal delay between requests
  - parallel page/session execution
  - concentrated error bursts in a short window
- Output focus:
  - throughput, drop behavior, rate-limit adherence, and recovery

## Execution Checklist

### Concurrency Foundation
- [ ] Add `Mom.Pipeline` ingestion/queue coordinator.
- [ ] Add `Mom.WorkerSupervisor` and bounded dispatch by `max_concurrency`.
- [ ] Route `Mom.Runner` events through pipeline enqueue path.
- [ ] Add per-job timeout/cancellation handling.
- [ ] Add in-flight signature guard for concurrent dedupe safety.

### Config and Controls
- [ ] Add config keys: `max_concurrency`, `queue_max_size`, `job_timeout_ms`, `overflow_policy`.
- [ ] Validate and enforce overflow behavior (`:drop_newest` / `:drop_oldest`).
- [ ] Add optional repo allowlist control (`allowed_github_repos`).
- [ ] Add branch naming policy support for Mom-generated branches.

### Observability and Audit
- [ ] Emit pipeline telemetry for enqueued/dropped/started/completed/failed jobs.
- [ ] Include queue depth, active worker count, job type, duration, and failure reason.
- [ ] Log Codex invocation + outcome for each run.
- [ ] Emit structured git/GitHub audit events (repo, issue/branch/PR, merge attempt, actor id).

### Test Execution Profile (Current)
- [ ] Run analysis/fix flow with `codex --yolo exec`.
- [ ] Enforce PR-only workflow to protected branches.
- [ ] Use least-privilege credential identity only.
- [ ] Validate burst scenario remains stable under bounded concurrency.

### Security Baseline
- [ ] Confirm dedicated machine identity (or GitHub App) is used.
- [ ] Confirm secrets are injected securely and redacted in logs.
- [ ] Confirm isolated worktrees are used for all mutations.
- [ ] Confirm network egress is restricted to required endpoints.
- [ ] Confirm unusual-activity alerts exist (PR spikes, auth failures, disallowed repo targets).

### Coverage and Validation
- [ ] Add unit tests for queue bounds, overflow policy, dispatch bounds, timeout, dedupe.
- [ ] Add integration burst tests for mixed diagnostics/error events.
- [ ] Add stress script/mix task for rapid local event generation.
- [ ] Validate readiness gate before enabling automated PR creation.
- [ ] Add/maintain ExUnit TDD coverage for every completed checklist task.
- [ ] Add/maintain Playwright coverage for every applicable end-to-end task (or record N/A rationale).

### Post-Validation Hardening
- [ ] Define `staging_restricted` policy (sandbox + command allowlist + write boundaries).
- [ ] Define `production_hardened` policy (restricted profile + sensitive-op approvals).
- [ ] Add fail-closed policy checks for safety violations.
- [ ] Add audit assertions for all agent-driven git mutations.
