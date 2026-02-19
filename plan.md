# Mom Remaining Plan (Failure Server First)

## Next 3 Tasks
1. [ ] Check in CI workflow manifests and required-check wiring for ExUnit + Playwright gates (including concurrency-report artifacts and fail-on-flaky enforcement) so branch protection can enforce reliability controls.
2. [ ] Harden observability acceptance metric-export synchronization (deterministic post-export assertions + bounded retries) to eliminate intermittent parallel-suite false negatives in release gates.
3. [ ] Add explicit runtime test-command execution controls (replace implicit `git mix test` behavior with policy-validated test command profiles) to ensure production test gating is reliable and auditable.

## Priority 0: Failure Server and Acceptance Reliability
- [x] Add automated harness branch-protection verification and evidence capture (required checks + review rules) before enabling burst-mode promotion gates.
 - Status: complete (February 19, 2026) via `mix mom.harness` branch-protection policy verification (`required_checks` + minimum approvals), persisted branch-protection evidence output (`acceptance/harness_branch_protection_evidence.json` by default), and ExUnit + Playwright acceptance coverage.
- [x] Stabilize Playwright full-suite execution lifecycle (detect/clean leaked `mix run` children and fail fast on lingering workers) to prevent acceptance-run hangs in CI and release gates.
- [x] Add acceptance runner build-artifact isolation controls (precompiled per-worker build dirs or serialized execution mode) to prevent Mix build-lock contention under parallel Playwright execution.
- [x] Add deterministic concurrency test instrumentation in CI (monitor-attach race hardening, flaky-test detection, and retry-budget policy) so reliability gates remain trustworthy under load.
- [ ] Check in CI workflow manifests and required-check wiring for ExUnit + Playwright gates (including concurrency-report artifacts and fail-on-flaky enforcement) so branch protection can enforce reliability controls.
- [ ] Harden observability acceptance metric-export synchronization (deterministic post-export assertions + bounded retries) to eliminate intermittent parallel-suite false negatives in release gates.
- [ ] Add explicit runtime test-command execution controls (replace implicit `git mix test` behavior with policy-validated test command profiles) to ensure production test gating is reliable and auditable.
- [ ] Enforce CI/runtime toolchain prerequisites for acceptance reliability (Node.js >= 18 and pinned Erlang/OTP patch level), with startup fail-fast checks.
- [ ] Add automated lifecycle cleanup for ephemeral acceptance build artifacts (`_build_runner_burst_*`, worker-scoped build dirs) with retention policy and startup pruning to prevent disk growth in long-lived runners.

## Priority 1: Operational Safety and Core Platform Readiness
- [x] Add disaster recovery runbook (backup/restore, credential revocation drill, failover steps).
 - Status: complete (February 19, 2026) via `mix mom.runbook` generator/validator, committed `docs/disaster_recovery_runbook.md`, and ExUnit + Playwright acceptance coverage.
- [ ] Add automated startup credential scope verification against GitHub App/PAT minimum permissions (contents, pull_requests, issues) with fail-closed behavior.
- [ ] Add policy-drift detection and attestation for execution profiles (detect runtime/config divergence from approved `staging_restricted`/`production_hardened` baselines and block unsafe starts).
- [ ] Add deterministic worktree temp-path lifecycle controls for test and runtime execution (collision-safe naming + startup cleanup) to prevent flaky failures and residue buildup.
- [ ] Add worker/process lifecycle safeguards for long-running operations (orphan process detection, forced timeout cleanup, and execution watchdog alerts).
- [ ] Add durable queue snapshot integrity/versioning controls (checksums, schema-versioned payloads, and corruption-recovery fallback) to protect replay reliability across upgrades.
- [ ] Replace static readiness-gate flag with signed/expiring readiness attestations (branch-protection check, credential-scope proof, and approval provenance).
- [ ] Remove deprecated ExUnit property registration usage (`ExUnit.Case.register_test/4`) to keep CI/test tooling forward-compatible with upcoming Elixir releases.
- [ ] Add scalable SOC2 evidence sink lifecycle controls (append-only writer, scheduled compaction, and file-locking strategy) to prevent audit-write contention and unbounded rewrite overhead under sustained production event rates.

## Priority 2: Security, Compliance, and Governance
- [ ] Add compliance controls (audit retention policy, SOC2 evidence hooks, PII handling policy).
- [ ] Add legal/governance package (ToS, DPA, subprocessors list, data residency options).
- [ ] Add data lifecycle controls (tenant-scoped export, retention windows, hard-delete workflow, legal hold support).
- [ ] Add tenant-facing data processing controls (per-tenant model/data retention toggles, legal-hold exceptions, and export attestations).
- [ ] Add model-provider governance controls (prompt/response retention policy enforcement, provider-level data use guarantees, and tenant-selectable model routing constraints).
- [ ] Add tamper-evident audit log integrity controls (event signing, verification tooling, and chain-of-custody reporting) for enterprise forensics.
- [ ] Add third-party dependency governance controls (SBOM generation, vulnerability SLA policy, and automated dependency risk gates).
- [ ] Add customer trust and assurance package (security whitepaper, penetration test cadence, vulnerability disclosure/bug bounty process).
- [ ] Add enterprise procurement security review workflow (security questionnaire automation, evidence bundle generation, and renewal tracking).

## Priority 3: Multi-Tenant Production Controls and Observability
- [ ] Add tenant-scoped observability and alerting (per-tenant queue depth, drop rate, failure rate, and quota-breach events) so multi-tenant SLOs are enforceable in production.
- [ ] Add runtime policy-violation alerting and response runbooks (severity tiers, paging thresholds, and automated escalation) to operationalize fail-closed controls in production.
- [ ] Add end-to-end trace correlation IDs linking pipeline jobs, Codex invocations, and Git/GitHub mutations for auditability and support forensics.
- [ ] Add worktree lifecycle management (automatic cleanup, retention windows, and stale-worktree quarantine) to prevent sensitive residue and disk exhaustion in long-running production deployments.
- [ ] Add control-plane high-availability targets and validation (RPO/RTO objectives, automated failover, and recurring recovery drills).

## Priority 4: Commercial and Customer Operations
- [ ] Add customer billing and entitlement enforcement (seat/repo plans, plan limits, overage policy, grace behavior, downgrade flow).
- [ ] Add billing-grade usage metering and reconciliation (LLM, CI, and repo actions) with invoice/audit traceability.
- [ ] Add finance and tax operations readiness (sales tax/VAT handling, invoice delivery/collections workflow, and revenue-recognition reporting exports).
- [ ] Add revenue operations controls for enterprise procurement (PO-based invoicing, payment terms enforcement, and collections escalation workflow).
- [ ] Add automated SLA credit workflows (policy mapping, breach detection, and credit issuance ledger integration).
- [ ] Add customer-facing SLA contract automation (policy templates, entitlement mapping, and auto-enforced remedy terms).
- [ ] Add customer identity and enterprise access controls (SSO/SAML, SCIM provisioning, enforced MFA).
- [ ] Add customer-facing change management controls (maintenance windows, tenant-targeted release channels, and backward-compatibility policy/versioning guarantees).
- [ ] Add customer trust portal capabilities (tenant-visible uptime/incidents, audit export self-service, and maintenance notification workflows).
- [ ] Add customer offboarding/deprovisioning workflows (tenant export verification, credential revocation, and timed hard-delete confirmation).
- [ ] Define 24x7 support and incident operations model (on-call rotations, incident response SLAs, escalation policy, status communication).
- [ ] Add operational onboarding docs (installation hardening, key rotation, upgrade playbook).
- [ ] Add customer support forensics tooling (tenant-scoped audit search, timeline reconstruction, and one-click incident evidence export).
- [ ] Add abuse/fraud controls for commercial usage (tenant anomaly detection, spend-spike auto-throttles, and chargeback dispute evidence workflows).
- [ ] Add tenant data residency controls (region pinning, cross-region failover policy, and residency-aware backups).
- [ ] Add tenant-scoped encryption and key management (at-rest encryption controls, KMS-backed key versioning, key rotation, optional BYOK support, and cryptographic deletion attestations).
- [ ] Add automated fix-quality and safety gates (regression benchmark suite, semantic diff risk scoring, and mandatory human approval path for high-risk patches).
- [ ] Add public launch-readiness controls (GA go/no-go checklist, rollback gate criteria, and launch-approver signoff evidence capture) to make release decisions auditable.
- [ ] Add self-serve customer operations control plane (tenant admin for billing/contact/security settings, delegated admin roles, and audit-visible change history) to reduce enterprise onboarding/support friction.
