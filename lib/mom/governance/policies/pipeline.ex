defmodule Mom.Governance.Policies.Pipeline do
  @moduledoc false

  defstruct [
    :max_concurrency,
    :queue_max_size,
    :tenant_queue_max_size,
    :job_timeout_ms,
    :overflow_policy,
    :durable_queue_path,
    :execution_watchdog_enabled,
    :execution_watchdog_orphan_grace_ms,
    :temp_worktree_max_active,
    :temp_worktree_alert_utilization_threshold
  ]

  @type t :: %__MODULE__{
          max_concurrency: non_neg_integer(),
          queue_max_size: pos_integer(),
          tenant_queue_max_size: pos_integer() | nil,
          job_timeout_ms: pos_integer(),
          overflow_policy: :drop_newest | :drop_oldest,
          durable_queue_path: String.t() | nil,
          execution_watchdog_enabled: boolean(),
          execution_watchdog_orphan_grace_ms: non_neg_integer(),
          temp_worktree_max_active: pos_integer(),
          temp_worktree_alert_utilization_threshold: float()
        }

  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = policy) do
    cond do
      policy.temp_worktree_max_active <= 0 ->
        {:error, "temp_worktree_max_active must be a positive integer"}

      policy.temp_worktree_alert_utilization_threshold < 0.0 or
          policy.temp_worktree_alert_utilization_threshold > 1.0 ->
        {:error, "temp_worktree_alert_utilization_threshold must be between 0.0 and 1.0"}

      true ->
        :ok
    end
  end
end
