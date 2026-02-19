# Mom Disaster Recovery Runbook

Generated on: 2026-02-19

## Backup and Restore

1. Pause new incident intake by stopping Mom pipeline workers.
2. Snapshot durable queue state and audit evidence store.
3. Verify snapshot checksum and copy to secondary storage.
4. Restore into a clean environment and run `mix test` before cutover.
5. Resume intake only after queue replay and audit-write health checks pass.

## Credential Revocation Drill

1. Revoke active GitHub/App/LLM credentials used by Mom.
2. Confirm revoked credentials fail with explicit auth errors.
3. Rotate secrets via managed secret storage and restart Mom with new values.
4. Validate startup scope checks pass for least-privilege permissions.
5. Record drill evidence (timestamps, actor, outcome) in the audit evidence sink.

## Failover Steps

1. Declare failover incident and page on-call owner.
2. Promote standby control plane and verify policy baselines are loaded.
3. Restore durable queue snapshot and replay pending jobs with bounded concurrency.
4. Validate GitHub/LLM connectivity, telemetry export, and alert delivery.
5. Communicate recovery status and backlog drain ETA to stakeholders.
