defmodule Mom.Governance.Policies.Observability do
  @moduledoc false

  defstruct [
    :backend,
    :export_path,
    :export_interval_ms,
    :slo_queue_depth_threshold,
    :slo_drop_rate_threshold,
    :slo_failure_rate_threshold,
    :slo_latency_p95_ms_threshold,
    :sla_triage_latency_p95_ms_target,
    :sla_queue_durability_target,
    :sla_pr_turnaround_p95_ms_target,
    :error_budget_triage_latency_overage_rate,
    :error_budget_queue_loss_rate,
    :error_budget_pr_turnaround_overage_rate
  ]

  @type t :: %__MODULE__{
          backend: :none | :prometheus,
          export_path: String.t() | nil,
          export_interval_ms: pos_integer(),
          slo_queue_depth_threshold: pos_integer(),
          slo_drop_rate_threshold: float(),
          slo_failure_rate_threshold: float(),
          slo_latency_p95_ms_threshold: pos_integer(),
          sla_triage_latency_p95_ms_target: pos_integer(),
          sla_queue_durability_target: float(),
          sla_pr_turnaround_p95_ms_target: pos_integer(),
          error_budget_triage_latency_overage_rate: float(),
          error_budget_queue_loss_rate: float(),
          error_budget_pr_turnaround_overage_rate: float()
        }

  @spec validate(t()) :: :ok
  def validate(%__MODULE__{}), do: :ok
end
