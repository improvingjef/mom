# Mom Remaining Plan (Failure Server First)

## Next 3 Tasks
1. [x] Add live GitHub credential permission evidence collection (App installation permissions + PAT scope introspection) with signed startup attestation to replace operator-declared scope inputs before GA.
 - Status: complete (February 19, 2026) via live GitHub permission evidence verification in `Mom.GitHubCredentialEvidence` (`x-oauth-scopes` PAT introspection + `/repos/{repo}/installation` permission checks), fail-closed startup gating with HMAC-signed attestation audit events in `Mom.Config`, and ExUnit + Playwright acceptance coverage.
2. [x] Add policy-drift detection and attestation for execution profiles (detect runtime/config divergence from approved `staging_restricted`/`production_hardened` baselines and block unsafe starts).
 - Status: complete (February 19, 2026) via startup baseline attestation in `Mom.Config` (`execution_profile_policy_attested`) with fail-closed drift blocking (`execution_profile_policy_drift_blocked`) across approved restricted-profile policy baselines, plus ExUnit + Playwright acceptance coverage.
3. [ ] Add deterministic worktree temp-path lifecycle controls for test and runtime execution (collision-safe naming + startup cleanup) to prevent flaky failures and residue buildup.

## Priority 0: Failure Server and Acceptance Reliability
- [x] Add automated harness branch-protection verification and evidence capture (required checks + review rules) before enabling burst-mode promotion gates.
 - Status: complete (February 19, 2026) via `mix mom.harness` branch-protection policy verification (`required_checks` + minimum approvals), persisted branch-protection evidence output (`acceptance/harness_branch_protection_evidence.json` by default), and ExUnit + Playwright acceptance coverage.
- [x] Stabilize Playwright full-suite execution lifecycle (detect/clean leaked `mix run` children and fail fast on lingering workers) to prevent acceptance-run hangs in CI and release gates.
- [x] Add acceptance runner build-artifact isolation controls (precompiled per-worker build dirs or serialized execution mode) to prevent Mix build-lock contention under parallel Playwright execution.
- [x] Add deterministic concurrency test instrumentation in CI (monitor-attach race hardening, flaky-test detection, and retry-budget policy) so reliability gates remain trustworthy under load.
- [x] Check in CI workflow manifests and required-check wiring for ExUnit + Playwright gates (including concurrency-report artifacts and fail-on-flaky enforcement) so branch protection can enforce reliability controls.
 - Status: complete (February 19, 2026) via checked-in GitHub Actions workflows (`.github/workflows/ci-exunit.yml`, `.github/workflows/ci-playwright.yml`), harness-integrated CI workflow verification (`Mom.CIWorkflow`), and ExUnit + Playwright acceptance coverage for required-check mapping and flaky/concurrency-report controls.
- [x] Harden observability acceptance metric-export synchronization (deterministic post-export assertions + bounded retries) to eliminate intermittent parallel-suite false negatives in release gates.
 - Status: complete (February 19, 2026) via deterministic observability export synchronization (`Mom.Observability.sync_export/1`), bounded full-metrics post-export assertions in acceptance (`acceptance/scripts/observability_prometheus_acceptance.exs`), and ExUnit + Playwright regression coverage.
- [x] Add explicit runtime test-command execution controls (replace implicit `git mix test` behavior with policy-validated test command profiles) to ensure production test gating is reliable and auditable.
 - Status: complete (February 19, 2026) via `test_command_profile` policy validation (`mix_test` / `mix_test_no_start` with execution-profile enforcement), runtime `mix test` command execution with structured audit evidence (`git_tests_run`), and ExUnit + Playwright acceptance coverage.
- [x] Enforce CI/runtime toolchain prerequisites for acceptance reliability (Node.js >= 18 and pinned Erlang/OTP patch level), with startup fail-fast checks.
 - Status: complete (February 19, 2026) via startup fail-fast toolchain validation in `Mom.Config` (Node.js major >= 18 and pinned OTP patch `28.0.2`), CI workflow OTP pinning updates, and ExUnit + Playwright acceptance coverage for blocked and passing paths.
- [x] Add automated lifecycle cleanup for ephemeral acceptance build artifacts (`_build_runner_burst_*`, worker-scoped build dirs) with retention policy and startup pruning to prevent disk growth in long-lived runners.
 - Status: complete (February 19, 2026) via startup pruning in `Mom.Config` using retention + keep-latest policy controls, `Mom.AcceptanceLifecycle` stale-artifact pruning for `_build_runner_burst_*`/worker-scoped build dirs, and ExUnit + Playwright acceptance coverage.
- [x] Enforce Elixir runtime patch-level prerequisites (stable 1.19.x baseline, reject release-candidate runtimes) with startup fail-fast validation to prevent environment drift and release-gate instability.
 - Status: complete (February 19, 2026) via startup fail-fast Elixir runtime validation in `Mom.Config` (stable `1.19.x` enforcement + RC rejection, with env/opts overrides for deterministic gating), and ExUnit + Playwright acceptance coverage for blocked and passing paths.

## Priority 1: Operational Safety and Core Platform Readiness
- [x] Add disaster recovery runbook (backup/restore, credential revocation drill, failover steps).
 - Status: complete (February 19, 2026) via `mix mom.runbook` generator/validator, committed `docs/disaster_recovery_runbook.md`, and ExUnit + Playwright acceptance coverage.
- [x] Add automated startup credential scope verification against GitHub App/PAT minimum permissions (contents, pull_requests, issues) with fail-closed behavior.
 - Status: complete (February 19, 2026) via fail-closed startup scope validation in `Mom.Config` (`github_credential_scopes` + `MOM_GITHUB_CREDENTIAL_SCOPES`), blocked-start audit evidence (`github_credential_scope_blocked`), `mix mom` CLI scope wiring, and ExUnit + Playwright acceptance coverage for blocked and passing paths.
- [x] Add live GitHub credential permission evidence collection (App installation permissions + PAT scope introspection) with signed startup attestation to replace operator-declared scope inputs before GA.
 - Status: complete (February 19, 2026) via `Mom.GitHubCredentialEvidence` PAT scope introspection (`x-oauth-scopes`) + installation permission evidence (`/repos/{repo}/installation`), HMAC-signed startup attestation audit events (`github_credential_permission_attested` / `github_credential_permission_blocked`), and ExUnit + Playwright acceptance coverage.
- [x] Add policy-drift detection and attestation for execution profiles (detect runtime/config divergence from approved `staging_restricted`/`production_hardened` baselines and block unsafe starts).
 - Status: complete (February 19, 2026) via approved-baseline policy attestation and fail-closed startup drift detection in `Mom.Config` (`execution_profile_policy_attested` / `execution_profile_policy_drift_blocked`), with ExUnit + Playwright acceptance coverage.
- [ ] Add deterministic worktree temp-path lifecycle controls for test and runtime execution (collision-safe naming + startup cleanup) to prevent flaky failures and residue buildup.
- [ ] Add local developer toolchain bootstrap + doctor command (`.tool-versions`/mise support, Node+OTP preflight, and actionable remediation output) to reduce onboarding drift and support escalation load before GA.
- [ ] Align Elixir runtime support policy with enforced startup/tooling checks (single supported patch baseline in `.tool-versions`/mise + `mix.exs` compatibility guardrails + CI parity checks) to prevent RC/stable mismatch startup blocks in operator and CI environments.
- [ ] Add worker/process lifecycle safeguards for long-running operations (orphan process detection, forced timeout cleanup, and execution watchdog alerts).
- [ ] Add acceptance-suite termination guardrails (post-suite Playwright parent-process liveness checks + bounded forced shutdown) to prevent CI hangs after all tests report passed.
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
- [ ] Add software supply-chain trust controls (release artifact signing, provenance attestations/SLSA, and verification gates for customer deployments).
- [ ] Add startup attestation signing-key rotation controls (dual-key overlap window, key-id governance, and forced re-attestation rollout) to support enterprise cryptographic hygiene.
- [ ] Add customer-verifiable attestation export and verification tooling (signed startup proof bundle + offline verifier) to reduce security-review friction during enterprise procurement.

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
- [ ] Add customer-facing product documentation and versioned API/CLI reference (quickstart, operational hardening guide, migration notes, and deprecation policy) to reduce enterprise onboarding friction and procurement risk.
- [ ] Add enterprise deal-desk and contract operations controls (MSA/DPA redline workflow, approval matrix, e-sign integration, and renewal ownership tracking) to prevent commercial bottlenecks during procurement and expansion.
