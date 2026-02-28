defmodule Mom.Governance.Configs.Observability do
  @moduledoc false

  alias Mom.Governance.Configs.Merge

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

  @spec config(keyword()) :: t()
  def config(cli_opts) do
    template =
      Application.fetch_env!(:mom, :config2_defaults)
      |> Map.fetch!(:observability)

    Merge.configure(template, cli_opts)
  end

  @spec parse_observability_backend(keyword(), keyword()) ::
          {:ok, :none | :prometheus} | {:error, String.t()}
  def parse_observability_backend(opts, runtime) do
    case Keyword.get(opts, :observability_backend, runtime[:observability_backend]) do
      :none -> {:ok, :none}
      :prometheus -> {:ok, :prometheus}
      "none" -> {:ok, :none}
      "prometheus" -> {:ok, :prometheus}
      nil -> {:error, "observability_backend must be :none or :prometheus"}
      _other -> {:error, "observability_backend must be :none or :prometheus"}
    end
  end

  @spec parse_observability_export_path(keyword(), keyword(), :none | :prometheus) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def parse_observability_export_path(opts, runtime, :none) do
    {:ok, Keyword.get(opts, :observability_export_path, runtime[:observability_export_path])}
  end

  def parse_observability_export_path(opts, runtime, :prometheus) do
    case Keyword.get(opts, :observability_export_path, runtime[:observability_export_path]) do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _other ->
        {:error,
         "observability_export_path is required when observability_backend is :prometheus"}
    end
  end
end
