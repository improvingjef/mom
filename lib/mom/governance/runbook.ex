defmodule Mom.Runbook do
  @moduledoc """
  Disaster recovery runbook generation and validation helpers.
  """

  @required_sections [
    "Backup and Restore",
    "Credential Revocation Drill",
    "Failover Steps",
    "Temp Worktree Saturation Response"
  ]

  @spec render(String.t()) :: String.t()
  def render(generated_on \\ Date.utc_today() |> Date.to_iso8601()) do
    """
    # Mom Disaster Recovery Runbook

    Generated on: #{generated_on}

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

    ## Temp Worktree Saturation Response

    1. Halt new mutation scheduling and inspect `temp_worktree_capacity_alert` / `temp_worktree_capacity_blocked` audit events.
    2. Run startup pruning with strict retention and verify stale `mom-worktree-*` directories were removed.
    3. If capacity remains saturated, raise `temp_worktree_max_active` only with incident approval and bounded rollback window.
    4. Validate `temp_worktree_capacity_observed` utilization drops below alert threshold before resuming traffic.
    5. Record root cause, disk metrics, and preventative retention tuning in the incident report.
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  @spec validate(String.t()) :: :ok | {:error, [String.t()]}
  def validate(markdown) when is_binary(markdown) do
    missing = Enum.reject(@required_sections, &String.contains?(markdown, "## " <> &1))

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  @spec required_sections() :: [String.t()]
  def required_sections, do: @required_sections
end
