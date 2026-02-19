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

## AS YOU GO
**As you build** the features, be certain to build an intentionally fragile Phoenix test app
- Create private GitHub repo via `gh`
- Run Mom against app repo
- Use Playwright in two modes:
  - human-paced baseline mode (default): realistic think time and navigation pacing
  - burst stress mode: rapid-fire concurrent fault triggering
- Evaluate issue/PR behavior and concurrency in realistic e2e flow


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

### Progress Update (February 19, 2026)
- Step 2 complete: concurrency config/flags and validation are implemented and covered by ExUnit + acceptance tests.
- Step 3 complete: `Mom.Runner` now routes error and diagnostics work through `Mom.Pipeline`, with worker-based engine execution and acceptance coverage.
- Step 3/4 follow-through complete: per-job timeout/cancellation handling is now covered by ExUnit worker tests and Playwright acceptance coverage.
- Step 5 complete: pipeline telemetry events (`enqueued`, `dropped`, `started`, `completed`, `failed`) and queue/worker structured lifecycle logs are implemented with ExUnit + Playwright acceptance coverage.
- Branch naming policy support for Mom-generated branches is implemented and covered by ExUnit + Playwright acceptance tests.
- Codex invocation/outcome logging is implemented (`mom: codex invocation started/completed`) and covered by ExUnit + Playwright acceptance tests.
- Structured git/GitHub audit events are implemented (repo, issue/branch/PR, merge attempt, actor id) and covered by ExUnit + Playwright acceptance tests.
- Secret handling hardening is implemented: CLI secret flags are blocked in favor of environment injection, and sensitive audit-log fields are redacted, covered by ExUnit + Playwright acceptance tests.
- Integration burst coverage for mixed diagnostics + error events is implemented with ExUnit + Playwright acceptance tests, including failure-isolation assertions under bounded concurrency.
- Codex execution profile defaults to `codex --yolo exec` (with override support), covered by ExUnit + Playwright acceptance tests.
- PR-only workflow enforcement for protected base branches is implemented (merge attempts are blocked for protected branches), covered by ExUnit + Playwright acceptance tests.
- Least-privilege credential identity enforcement is implemented via actor allowlist controls for GitHub-token flows, covered by ExUnit + Playwright acceptance tests.
- Dedicated machine identity enforcement for GitHub-token flows is implemented (bot/app actor pattern required), covered by ExUnit + Playwright acceptance tests.
- Network egress policy enforcement is implemented: outbound GitHub/LLM hosts are restricted to an allowlist with fail-closed validation/runtime checks, covered by ExUnit + Playwright acceptance tests.
- Unusual-activity alerting is implemented for PR spikes, auth failure spikes, and disallowed repo target attempts, covered by ExUnit + Playwright acceptance tests.

4. Add In-Flight Signature Guard
- Prevent duplicate concurrent work for same signature window.
- Ensure cleanup on both success and failure.

5. Telemetry + Structured Logs
- Add events and log fields for queue/worker visibility.
 - Status: complete (February 19, 2026).

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

## Commercial Availability Additions (New)

1. Production Observability Integration
- Export pipeline telemetry to a production backend (OpenTelemetry/Prometheus), with dashboards and SLO alerts for queue depth, drop rate, failure rate, and triage latency.

2. Delivery Safety and Governance
- Enforce protected-branch PR approvals, required CI checks, and policy gates for Mom-authored changes before merge.

3. End-to-End Security Hardening
- Implement restricted execution profiles (remove default `--yolo` in production), outbound egress controls, and audited command allowlists.

4. Credential and Secret Operations
- Move all credentials to managed secret storage, add rotation automation, and add startup/runtime checks for stale or over-scoped credentials.

5. Release and Rollback Readiness
- Add versioned release pipeline, artifact signing/provenance, staged rollout (dev/stage/prod), and documented rollback playbook.

6. Multi-Tenant and Abuse Controls
- Add per-repo quotas, per-tenant concurrency isolation, and anomaly throttling to prevent noisy or malicious workloads from starving capacity.
- Validate stability and throughput against success criteria.

8. Readiness Gate for E2E Harness
- Proceed to Phoenix + Playwright harness only after criteria are met.
- Security checklist above must pass before enabling automated PR creation.

## Commercial Availability Backlog (New)

9. Multi-tenant and Access Control Foundations
- Add tenant/project scoping for repos, credentials, limits, and audit history.
- Introduce operator authn/authz (role-based controls for run/approve/merge operations).

10. Durable State + Recovery
- Persist queue/job state and retry metadata across process restarts.
- Add restart/replay semantics so in-flight work can resume safely after crashes.

11. Production Observability + Alerting
- Export metrics for queue depth, worker saturation, drop rates, and job latency.
- Add alert rules and runbooks for saturation, auth failures, and repeated job failures.

12. Reliability Controls for LLM/Git Operations
- Add explicit retry/backoff/circuit-breaker policies per external dependency.
- Add idempotency keys for issue/PR creation to prevent duplicate mutations.

13. Compliance and Governance
- Add immutable audit log sinks and retention controls.
- Add policy checks for approved repo targets, branch naming, and restricted operations.

14. Packaging and Operability
- Ship a container image + deployment manifests for at least one production target (Kubernetes or systemd).
- Add operator docs: install, upgrade, rollback, incident handling, and credential rotation.

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
- [x] Add `Mom.Pipeline` ingestion/queue coordinator.
- [x] Add `Mom.WorkerSupervisor` and bounded dispatch by `max_concurrency`.
- [x] Route `Mom.Runner` events through pipeline enqueue path.
- [x] Add per-job timeout/cancellation handling.
- [x] Add in-flight signature guard for concurrent dedupe safety.

### Config and Controls
- [x] Add config keys: `max_concurrency`, `queue_max_size`, `job_timeout_ms`, `overflow_policy`.
- [x] Validate and enforce overflow behavior (`:drop_newest` / `:drop_oldest`).
- [x] Add optional repo allowlist control (`allowed_github_repos`).
- [x] Add branch naming policy support for Mom-generated branches.

### Observability and Audit
- [x] Emit pipeline telemetry for enqueued/dropped/started/completed/failed jobs.
- [x] Include queue depth, active worker count, job type, duration, and failure reason.
- [x] Log Codex invocation + outcome for each run.
- [x] Emit structured git/GitHub audit events (repo, issue/branch/PR, merge attempt, actor id).

### Test Execution Profile (Current)
- [x] Run analysis/fix flow with `codex --yolo exec`.
- [x] Enforce PR-only workflow to protected branches.
- [x] Use least-privilege credential identity only.
- [x] Validate burst scenario remains stable under bounded concurrency.

### Security Baseline
- [x] Confirm dedicated machine identity (or GitHub App) is used.
- [x] Confirm secrets are injected securely and redacted in logs.
- [x] Confirm isolated worktrees are used for all mutations.
- [x] Confirm network egress is restricted to required endpoints.
- [x] Confirm unusual-activity alerts exist (PR spikes, auth failures, disallowed repo targets).

### Coverage and Validation
- [x] Add unit tests for queue bounds, overflow policy, dispatch bounds, timeout, dedupe.
- [x] Add integration burst tests for mixed diagnostics/error events.
- [ ] Add stress script/mix task for rapid local event generation.
- [ ] Validate readiness gate before enabling automated PR creation.
- [ ] Add/maintain ExUnit TDD coverage for every completed checklist task.
- [ ] Add/maintain Playwright coverage for every applicable end-to-end task (or record N/A rationale).

### Post-Validation Hardening
- [ ] Define `staging_restricted` policy (sandbox + command allowlist + write boundaries).
- [ ] Define `production_hardened` policy (restricted profile + sensitive-op approvals).
- [ ] Add fail-closed policy checks for safety violations.
- [ ] Add audit assertions for all agent-driven git mutations.

## Commercial Availability Backlog
- [ ] Define SLA/SLO targets (triage latency, queue durability, PR turnaround) and error budgets.
- [ ] Add durable queue mode (disk-backed persistence and replay on restart) for production resilience.
- [ ] Add multi-tenant controls (per-repo quotas, isolation boundaries, and fairness scheduling).
- [ ] Add cost controls and spend caps for LLM/token/test execution per repository.
- [ ] Add compliance controls (audit retention policy, SOC2 evidence hooks, PII handling policy).
- [ ] Add disaster recovery runbook (backup/restore, credential revocation drill, failover steps).
- [ ] Add customer-facing billing and entitlement enforcement (plan limits, overage handling, downgrade flow).
- [ ] Define support and incident operations model (on-call rotations, escalation policy, status communication).
- [ ] Add operational onboarding docs (installation hardening, key rotation, upgrade playbook).
- [ ] Add customer billing and entitlement enforcement (seat/repo plans, overage policy, grace behavior).
- [ ] Add 24x7 operational support model (on-call rotation, incident response SLAs, escalation paths).
- [ ] Add legal/governance package (ToS, DPA, subprocessors list, data residency options).
- [ ] Add customer identity and enterprise access controls (SSO/SAML, SCIM provisioning, enforced MFA).
- [ ] Add data lifecycle controls (tenant-scoped export, retention windows, hard-delete workflow, legal hold support).
- [ ] Add billing-grade usage metering and reconciliation (LLM, CI, and repo actions) with invoice/audit traceability.
- [ ] Add tenant-scoped encryption and key management (at-rest encryption controls, key rotation, and optional BYOK support).
- [ ] Add revenue operations controls for enterprise procurement (PO-based invoicing, payment terms enforcement, and collections escalation workflow).
- [ ] Add customer-facing change management controls (maintenance windows, tenant-targeted release channels, and backward-compatibility policy/versioning guarantees).
- [ ] Add data loss prevention controls for generated patches/issues/PRs (secret scanning + policy enforcement before push/open PR).
- [ ] Add customer support forensics tooling (tenant-scoped audit search, timeline reconstruction, and one-click incident evidence export).
- [ ] Add third-party dependency governance controls (SBOM generation, vulnerability SLA policy, and automated dependency risk gates).
- [ ] Add tenant-facing data processing controls (per-tenant model/data retention toggles, legal-hold exceptions, and export attestations).

## Commercial Availability Backlog (Additional)
- [ ] Add tenant data residency controls (region pinning, cross-region failover policy, and residency-aware backups).
- [ ] Add customer trust and assurance package (security whitepaper, penetration test cadence, vulnerability disclosure/bug bounty process).
- [ ] Add finance and tax operations readiness (sales tax/VAT handling, invoice delivery/collections workflow, and revenue-recognition reporting exports).
- [ ] Add worktree lifecycle management (automatic cleanup, retention windows, and stale-worktree quarantine) to prevent sensitive residue and disk exhaustion in long-running production deployments.
- [ ] Add automated startup credential scope verification against GitHub App/PAT minimum permissions (contents, pull_requests, issues) with fail-closed behavior.
- [ ] Add end-to-end trace correlation IDs linking pipeline jobs, Codex invocations, and Git/GitHub mutations for auditability and support forensics.
- [ ] Add control-plane high-availability targets and validation (RPO/RTO objectives, automated failover, and recurring recovery drills).
- [ ] Add customer trust portal capabilities (tenant-visible uptime/incidents, audit export self-service, and maintenance notification workflows).
- [ ] Add model-provider governance controls (prompt/response retention policy enforcement, provider-level data use guarantees, and tenant-selectable model routing constraints).
- [ ] Add automated SLA credit workflows (policy mapping, breach detection, and credit issuance ledger integration).
- [ ] Add customer offboarding/deprovisioning workflows (tenant export verification, credential revocation, and timed hard-delete confirmation).
- [ ] Add automated fix-quality and safety gates (regression benchmark suite, semantic diff risk scoring, and mandatory human approval path for high-risk patches).
- [ ] Add abuse/fraud controls for commercial usage (tenant anomaly detection, spend-spike auto-throttles, and chargeback dispute evidence workflows).
- [ ] Add customer-facing SLA contract automation (policy templates, entitlement mapping, and auto-enforced remedy terms).
- [ ] Add enterprise procurement security review workflow (security questionnaire automation, evidence bundle generation, and renewal tracking).
