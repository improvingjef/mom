# Mom Plan: Incident-to-PR Only

## Objective
Execute and harden one path only:
1. Incident is detected.
2. Mom diagnoses and generates a fix + regression test.
3. Tests run and pass in isolated worktree.
4. Branch is pushed and PR is opened.

## Scope Rule
- No task may be added unless it directly improves reliability or observability of the incident-to-PR path above.
- Ignore all other roadmap/commercial/platform work until this path is consistently reliable.

## Current Priority
- [ ] Complete a verified live run against `improvingjef/mom-fragile-phoenix-harness` that ends with a real GitHub PR URL.

## Critical Path Tasks
- [ ] Ensure harness repo contains executable failure scenarios and a testable codebase (`mix.exs`, failing mode, tests).
- [ ] Trigger deterministic incident input that reproduces a real failure mode.
- [ ] Run Mom with PR-enabled config (`open_pr=true`, `readiness_gate_approved=true`, protected base branch policy satisfied).
- [ ] Verify LLM patch application succeeds (valid unified diff + applies cleanly).
- [ ] Verify Mom adds/updates regression tests when needed.
- [ ] Verify test command executes successfully in isolated worktree.
- [ ] Verify branch push succeeds to GitHub.
- [ ] Verify PR creation succeeds and capture PR URL/number.

## Reliability Gates (Only for This Path)
- [x] Add a single acceptance test that asserts end-to-end incident-to-PR success signal (including PR create event).
  - Status: complete (February 20, 2026) via `acceptance/tests/incident_to_pr.spec.js` + `acceptance/scripts/incident_to_pr_success_acceptance.exs`, backed by `Mom.IncidentToPr` ExUnit coverage (`test/incident_to_pr_test.exs`).
- [ ] Add failure classification for each stop point in the path: detect, patch apply, tests, push, PR create.
- [x] Add retry policy only where it improves this path (patch apply conflict or transient GitHub/API failures).
  - Status: complete (February 20, 2026) via burst-workload acceptance retry hardening: adaptive timeout budgets, deterministic retry backoff for `runner_burst`, and ETIMEDOUT retry classification in `acceptance/tests/helpers/mix_runner.js` with ExUnit + Playwright coverage.
- [ ] Add timeout forensics for repeated `runner_burst` ETIMEDOUT attempts (capture attempt-level process snapshot and classification payload) to reduce MTTR when host contention blocks incident-to-PR validation runs.

## Done Criteria
- [ ] At least one reproducible live run produces a real PR in the harness repo.
- [x] Acceptance coverage exists for the complete path and passes.
- [ ] Production CI runs incident-to-PR acceptance (`acceptance/tests/incident_to_pr.spec.js`) on every protected-branch change and uploads artifacts for audit evidence.
- [ ] GitHub credential posture is commercially ready: rotate/revoke runbook exercised and app/token scope attestation enforced in release gating.
- [ ] On-call operational readiness is in place: incident-to-PR success-rate SLO, alert routing, and runbook-linked failure triage for each stop point.
- [ ] Plan remains restricted to incident-to-PR tasks only.
