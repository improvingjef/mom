defmodule Mom.Governance.Configs.Pipeline do
  @moduledoc false

  alias Mom.Governance.Configs.Merge

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

  @spec config(keyword()) :: t()
  def config(cli_opts) do
    template =
      Application.fetch_env!(:mom, :config2_defaults)
      |> Map.fetch!(:pipeline)

    Merge.configure(template, cli_opts)
  end

  @spec parse_overflow_policy(keyword(), keyword()) ::
          {:ok, :drop_newest | :drop_oldest} | {:error, String.t()}
  def parse_overflow_policy(opts, runtime) do
    case Keyword.get(opts, :overflow_policy, runtime[:overflow_policy]) do
      :drop_newest -> {:ok, :drop_newest}
      :drop_oldest -> {:ok, :drop_oldest}
      "drop_newest" -> {:ok, :drop_newest}
      "drop_oldest" -> {:ok, :drop_oldest}
      nil -> {:error, "overflow_policy must be :drop_newest or :drop_oldest"}
      _other -> {:error, "overflow_policy must be :drop_newest or :drop_oldest"}
    end
  end

  @spec parse_execution_watchdog_enabled(keyword(), keyword()) ::
          {:ok, boolean()} | {:error, String.t()}
  def parse_execution_watchdog_enabled(opts, runtime) do
    case Keyword.get(opts, :execution_watchdog_enabled, runtime[:execution_watchdog_enabled]) do
      nil -> {:ok, runtime[:execution_watchdog_enabled]}
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, "execution_watchdog_enabled must be a boolean"}
    end
  end

  @spec parse_durable_queue_path(keyword(), keyword()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def parse_durable_queue_path(opts, runtime) do
    case Keyword.get(opts, :durable_queue_path, runtime[:durable_queue_path]) do
      nil ->
        {:ok, nil}

      path when is_binary(path) ->
        trimmed = String.trim(path)

        if trimmed == "",
          do: {:error, "durable_queue_path must be nil or a non-empty string"},
          else: {:ok, trimmed}

      _other ->
        {:error, "durable_queue_path must be nil or a non-empty string"}
    end
  end
end
