defmodule Mom.Config do
  @moduledoc false

  alias Mom.Audit

  @type llm_provider :: :claude_code | :codex | :api_anthropic | :api_openai

  defstruct [
    :repo,
    :node,
    :cookie,
    :mode,
    :llm_provider,
    :llm_cmd,
    :execution_profile,
    :sandbox_mode,
    :command_allowlist,
    :write_boundaries,
    :llm_api_key,
    :llm_api_url,
    :llm_model,
    :triage_on_diagnostics,
    :triage_mode,
    :diag_run_queue_mult,
    :diag_mem_high_bytes,
    :diag_cooldown_ms,
    :issue_rate_limit_per_hour,
    :llm_rate_limit_per_hour,
    :llm_spend_cap_cents_per_hour,
    :llm_call_cost_cents,
    :llm_token_cap_per_hour,
    :llm_tokens_per_call_estimate,
    :test_spend_cap_cents_per_hour,
    :test_run_cost_cents,
    :issue_dedupe_window_ms,
    :redact_keys,
    :git_ssh_command,
    :open_pr,
    :merge_pr,
    :readiness_gate_approved,
    :poll_interval_ms,
    :max_concurrency,
    :queue_max_size,
    :tenant_queue_max_size,
    :job_timeout_ms,
    :overflow_policy,
    :durable_queue_path,
    :observability_backend,
    :observability_export_path,
    :observability_export_interval_ms,
    :slo_queue_depth_threshold,
    :slo_drop_rate_threshold,
    :slo_failure_rate_threshold,
    :slo_latency_p95_ms_threshold,
    :sla_triage_latency_p95_ms_target,
    :sla_queue_durability_target,
    :sla_pr_turnaround_p95_ms_target,
    :error_budget_triage_latency_overage_rate,
    :error_budget_queue_loss_rate,
    :error_budget_pr_turnaround_overage_rate,
    :allowed_github_repos,
    :allowed_actor_ids,
    :branch_name_prefix,
    :allowed_egress_hosts,
    :min_level,
    :dry_run,
    :github_token,
    :github_repo,
    :github_base_branch,
    :protected_branches,
    :actor_id,
    :workdir
  ]

  @type t :: %__MODULE__{
          repo: String.t(),
          node: node() | nil,
          cookie: atom() | nil,
          mode: :remote | :inproc,
          llm_provider: llm_provider(),
          llm_cmd: String.t() | nil,
          execution_profile: :test_relaxed | :staging_restricted | :production_hardened,
          sandbox_mode: :unrestricted | :workspace_write | :read_only,
          command_allowlist: [String.t()],
          write_boundaries: [String.t()],
          llm_api_key: String.t() | nil,
          llm_api_url: String.t() | nil,
          llm_model: String.t() | nil,
          triage_on_diagnostics: boolean(),
          triage_mode: :report | :fix,
          diag_run_queue_mult: pos_integer(),
          diag_mem_high_bytes: pos_integer(),
          diag_cooldown_ms: pos_integer(),
          issue_rate_limit_per_hour: pos_integer(),
          llm_rate_limit_per_hour: pos_integer(),
          llm_spend_cap_cents_per_hour: pos_integer() | nil,
          llm_call_cost_cents: non_neg_integer(),
          llm_token_cap_per_hour: pos_integer() | nil,
          llm_tokens_per_call_estimate: non_neg_integer(),
          test_spend_cap_cents_per_hour: pos_integer() | nil,
          test_run_cost_cents: non_neg_integer(),
          issue_dedupe_window_ms: pos_integer(),
          redact_keys: [String.t()],
          git_ssh_command: String.t() | nil,
          open_pr: boolean(),
          merge_pr: boolean(),
          readiness_gate_approved: boolean(),
          poll_interval_ms: non_neg_integer(),
          max_concurrency: non_neg_integer(),
          queue_max_size: pos_integer(),
          tenant_queue_max_size: pos_integer() | nil,
          job_timeout_ms: pos_integer(),
          overflow_policy: :drop_newest | :drop_oldest,
          durable_queue_path: String.t() | nil,
          observability_backend: :none | :prometheus,
          observability_export_path: String.t() | nil,
          observability_export_interval_ms: pos_integer(),
          slo_queue_depth_threshold: pos_integer(),
          slo_drop_rate_threshold: float(),
          slo_failure_rate_threshold: float(),
          slo_latency_p95_ms_threshold: pos_integer(),
          sla_triage_latency_p95_ms_target: pos_integer(),
          sla_queue_durability_target: float(),
          sla_pr_turnaround_p95_ms_target: pos_integer(),
          error_budget_triage_latency_overage_rate: float(),
          error_budget_queue_loss_rate: float(),
          error_budget_pr_turnaround_overage_rate: float(),
          allowed_github_repos: [String.t()],
          allowed_actor_ids: [String.t()],
          branch_name_prefix: String.t(),
          allowed_egress_hosts: [String.t()],
          min_level: :error | :warning | :info,
          dry_run: boolean(),
          github_token: String.t() | nil,
          github_repo: String.t() | nil,
          github_base_branch: String.t(),
          protected_branches: [String.t()],
          actor_id: String.t(),
          workdir: String.t() | nil
        }

  @spec from_opts(keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_opts(opts) do
    repo = Keyword.get(opts, :repo)
    runtime = Application.get_all_env(:mom)
    redact_keys = normalize_redact_keys(Keyword.get(opts, :redact_keys) || runtime[:redact_keys])
    llm_provider = Keyword.get(opts, :llm_provider, :claude_code)
    llm_cmd_override = Keyword.get(opts, :llm_cmd) || runtime[:llm_cmd]
    llm_api_url = Keyword.get(opts, :llm_api_url) || runtime[:llm_api_url]

    cond do
      is_nil(repo) ->
        {:error, "repo is required"}

      true ->
        github_token = secret_from_opts_or_env(opts, runtime, :github_token, "MOM_GITHUB_TOKEN")
        llm_api_key = secret_from_opts_or_env(opts, runtime, :llm_api_key, "MOM_LLM_API_KEY")
        actor_id = parse_actor_id(opts, runtime)

        with {:ok, max_concurrency} <- parse_non_neg_int(opts, runtime, :max_concurrency, 4),
             {:ok, queue_max_size} <- parse_pos_int(opts, runtime, :queue_max_size, 200),
             {:ok, tenant_queue_max_size} <-
               parse_optional_pos_int(opts, runtime, :tenant_queue_max_size),
             {:ok, llm_spend_cap_cents_per_hour} <-
               parse_optional_pos_int(opts, runtime, :llm_spend_cap_cents_per_hour),
             {:ok, llm_call_cost_cents} <-
               parse_non_neg_int(opts, runtime, :llm_call_cost_cents, 0),
             {:ok, llm_token_cap_per_hour} <-
               parse_optional_pos_int(opts, runtime, :llm_token_cap_per_hour),
             {:ok, llm_tokens_per_call_estimate} <-
               parse_non_neg_int(opts, runtime, :llm_tokens_per_call_estimate, 0),
             {:ok, test_spend_cap_cents_per_hour} <-
               parse_optional_pos_int(opts, runtime, :test_spend_cap_cents_per_hour),
             {:ok, test_run_cost_cents} <-
               parse_non_neg_int(opts, runtime, :test_run_cost_cents, 0),
             {:ok, job_timeout_ms} <- parse_pos_int(opts, runtime, :job_timeout_ms, 120_000),
             {:ok, overflow_policy} <- parse_overflow_policy(opts, runtime),
             {:ok, durable_queue_path} <- parse_durable_queue_path(opts, runtime),
             {:ok, observability_backend} <- parse_observability_backend(opts, runtime),
             {:ok, observability_export_path} <-
               parse_observability_export_path(opts, runtime, observability_backend),
             {:ok, observability_export_interval_ms} <-
               parse_pos_int(opts, runtime, :observability_export_interval_ms, 5_000),
             {:ok, slo_queue_depth_threshold} <-
               parse_pos_int(opts, runtime, :slo_queue_depth_threshold, 150),
             {:ok, slo_drop_rate_threshold} <-
               parse_ratio(opts, runtime, :slo_drop_rate_threshold, 0.05),
             {:ok, slo_failure_rate_threshold} <-
               parse_ratio(opts, runtime, :slo_failure_rate_threshold, 0.1),
             {:ok, slo_latency_p95_ms_threshold} <-
               parse_pos_int(opts, runtime, :slo_latency_p95_ms_threshold, 15_000),
             {:ok, sla_triage_latency_p95_ms_target} <-
               parse_pos_int(opts, runtime, :sla_triage_latency_p95_ms_target, 15_000),
             {:ok, sla_queue_durability_target} <-
               parse_ratio(opts, runtime, :sla_queue_durability_target, 0.995),
             {:ok, sla_pr_turnaround_p95_ms_target} <-
               parse_pos_int(opts, runtime, :sla_pr_turnaround_p95_ms_target, 900_000),
             {:ok, error_budget_triage_latency_overage_rate} <-
               parse_ratio(opts, runtime, :error_budget_triage_latency_overage_rate, 0.05),
             {:ok, error_budget_queue_loss_rate} <-
               parse_ratio(opts, runtime, :error_budget_queue_loss_rate, 0.005),
             {:ok, error_budget_pr_turnaround_overage_rate} <-
               parse_ratio(opts, runtime, :error_budget_pr_turnaround_overage_rate, 0.1),
             {:ok, allowed_github_repos} <- parse_allowed_github_repos(opts, runtime),
             {:ok, allowed_actor_ids} <- parse_allowed_actor_ids(opts, runtime),
             {:ok, branch_name_prefix} <- parse_branch_name_prefix(opts, runtime),
             {:ok, allowed_egress_hosts} <- parse_allowed_egress_hosts(opts, runtime),
             :ok <-
               validate_required_egress_hosts(llm_provider, llm_api_url, allowed_egress_hosts),
             {:ok, github_base_branch} <- parse_github_base_branch(opts, runtime),
             {:ok, protected_branches} <-
               parse_protected_branches(opts, runtime, github_base_branch),
             {:ok, readiness_gate_approved} <- parse_readiness_gate_approved(opts, runtime),
             {:ok, merge_pr} <- parse_merge_pr(opts, runtime),
             {:ok, workdir} <- parse_workdir(opts, runtime),
             {:ok, execution_profile} <- parse_execution_profile(opts, runtime),
             {:ok, open_pr} <- parse_open_pr(opts, runtime, execution_profile: execution_profile),
             llm_cmd <- default_llm_cmd(llm_provider, llm_cmd_override, execution_profile),
             policy <- execution_policy(execution_profile, workdir),
             :ok <-
               validate_execution_policy(
                 execution_profile,
                 llm_provider,
                 llm_cmd,
                 workdir,
                 open_pr,
                 merge_pr,
                 readiness_gate_approved
               ),
             :ok <- validate_actor_identity(actor_id, github_token, allowed_actor_ids),
             :ok <-
               validate_automated_pr_readiness(
                 open_pr,
                 github_token,
                 Keyword.get(opts, :github_repo) || runtime[:github_repo],
                 readiness_gate_approved,
                 actor_id,
                 github_base_branch,
                 protected_branches
               ),
             {:ok, github_repo} <-
               parse_and_validate_github_repo(opts, runtime, allowed_github_repos, actor_id) do
          {:ok,
           %__MODULE__{
             repo: repo,
             node: Keyword.get(opts, :node),
             cookie: Keyword.get(opts, :cookie),
             mode: Keyword.get(opts, :mode, :remote),
             llm_provider: llm_provider,
             llm_cmd: llm_cmd,
             execution_profile: execution_profile,
             sandbox_mode: policy.sandbox_mode,
             command_allowlist: policy.command_allowlist,
             write_boundaries: policy.write_boundaries,
             llm_api_key: llm_api_key,
             llm_api_url: llm_api_url,
             llm_model: Keyword.get(opts, :llm_model) || runtime[:llm_model],
             triage_on_diagnostics: Keyword.get(opts, :triage_on_diagnostics, false),
             triage_mode: Keyword.get(opts, :triage_mode, :report),
             diag_run_queue_mult: Keyword.get(opts, :diag_run_queue_mult, 4),
             diag_mem_high_bytes: Keyword.get(opts, :diag_mem_high_bytes, 2 * 1024 * 1024 * 1024),
             diag_cooldown_ms: Keyword.get(opts, :diag_cooldown_ms, 300_000),
             issue_rate_limit_per_hour:
               parse_int(
                 Keyword.get(opts, :issue_rate_limit_per_hour) ||
                   runtime[:issue_rate_limit_per_hour]
               ) ||
                 60,
             llm_rate_limit_per_hour:
               parse_int(
                 Keyword.get(opts, :llm_rate_limit_per_hour) || runtime[:llm_rate_limit_per_hour]
               ) ||
                 60,
             llm_spend_cap_cents_per_hour: llm_spend_cap_cents_per_hour,
             llm_call_cost_cents: llm_call_cost_cents,
             llm_token_cap_per_hour: llm_token_cap_per_hour,
             llm_tokens_per_call_estimate: llm_tokens_per_call_estimate,
             test_spend_cap_cents_per_hour: test_spend_cap_cents_per_hour,
             test_run_cost_cents: test_run_cost_cents,
             issue_dedupe_window_ms:
               parse_int(
                 Keyword.get(opts, :issue_dedupe_window_ms) || runtime[:issue_dedupe_window_ms]
               ) ||
                 3_600_000,
             redact_keys: redact_keys,
             git_ssh_command: Keyword.get(opts, :git_ssh_command) || runtime[:git_ssh_command],
             open_pr: open_pr,
             merge_pr: merge_pr,
             readiness_gate_approved: readiness_gate_approved,
             poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 5_000),
             max_concurrency: max_concurrency,
             queue_max_size: queue_max_size,
             tenant_queue_max_size: tenant_queue_max_size,
             job_timeout_ms: job_timeout_ms,
             overflow_policy: overflow_policy,
             durable_queue_path: durable_queue_path,
             observability_backend: observability_backend,
             observability_export_path: observability_export_path,
             observability_export_interval_ms: observability_export_interval_ms,
             slo_queue_depth_threshold: slo_queue_depth_threshold,
             slo_drop_rate_threshold: slo_drop_rate_threshold,
             slo_failure_rate_threshold: slo_failure_rate_threshold,
             slo_latency_p95_ms_threshold: slo_latency_p95_ms_threshold,
             sla_triage_latency_p95_ms_target: sla_triage_latency_p95_ms_target,
             sla_queue_durability_target: sla_queue_durability_target,
             sla_pr_turnaround_p95_ms_target: sla_pr_turnaround_p95_ms_target,
             error_budget_triage_latency_overage_rate: error_budget_triage_latency_overage_rate,
             error_budget_queue_loss_rate: error_budget_queue_loss_rate,
             error_budget_pr_turnaround_overage_rate: error_budget_pr_turnaround_overage_rate,
             allowed_github_repos: allowed_github_repos,
             allowed_actor_ids: allowed_actor_ids,
             branch_name_prefix: branch_name_prefix,
             allowed_egress_hosts: allowed_egress_hosts,
             min_level: Keyword.get(opts, :min_level, :error),
             dry_run: Keyword.get(opts, :dry_run, false),
             github_token: github_token,
             github_repo: github_repo,
             github_base_branch: github_base_branch,
             protected_branches: protected_branches,
             actor_id: actor_id,
             workdir: workdir
           }}
        end
    end
  end

  @spec validate_runtime_policy(t()) :: :ok | {:error, String.t()}
  def validate_runtime_policy(%__MODULE__{execution_profile: :test_relaxed}), do: :ok

  def validate_runtime_policy(%__MODULE__{} = config) do
    policy = execution_policy(config.execution_profile, config.workdir)

    with :ok <- validate_policy_alignment(config, policy),
         :ok <-
           validate_execution_policy(
             config.execution_profile,
             config.llm_provider,
             config.llm_cmd,
             config.workdir,
             config.open_pr,
             config.merge_pr,
             config.readiness_gate_approved
           ) do
      :ok
    end
  end

  defp default_llm_cmd(:codex, nil, :staging_restricted),
    do: "codex exec --sandbox workspace-write"

  defp default_llm_cmd(:codex, nil, :production_hardened),
    do: "codex exec --sandbox read-only"

  defp default_llm_cmd(:codex, nil, _profile), do: "codex --yolo exec"
  defp default_llm_cmd(_provider, cmd, _profile), do: cmd

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(value) when is_integer(value), do: value * 1.0
  defp parse_float(value) when is_float(value), do: value

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp secret_from_opts_or_env(opts, runtime, key, env_var) do
    Keyword.get(opts, key) || runtime[key] || System.get_env(env_var)
  end

  defp normalize_redact_keys(nil), do: default_redact_keys()
  defp normalize_redact_keys(keys) when is_list(keys), do: Enum.map(keys, &to_string/1)

  defp normalize_redact_keys(keys) when is_binary(keys) do
    keys
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default_redact_keys()
      list -> list
    end
  end

  defp default_redact_keys do
    [
      "password",
      "passwd",
      "secret",
      "token",
      "api_key",
      "apikey",
      "authorization",
      "cookie"
    ]
  end

  defp parse_allowed_github_repos(opts, runtime) do
    value = Keyword.get(opts, :allowed_github_repos, runtime[:allowed_github_repos])
    {:ok, normalize_allowed_repos(value)}
  end

  defp parse_allowed_actor_ids(opts, runtime) do
    value = Keyword.get(opts, :allowed_actor_ids, runtime[:allowed_actor_ids])
    {:ok, normalize_allowed_repos(value)}
  end

  defp parse_allowed_egress_hosts(opts, runtime) do
    value = Keyword.get(opts, :allowed_egress_hosts, runtime[:allowed_egress_hosts])

    hosts =
      case normalize_allowed_repos(value) do
        [] -> default_allowed_egress_hosts()
        parsed -> Enum.uniq(parsed)
      end
      |> Enum.map(&String.downcase/1)

    if Enum.all?(hosts, &valid_host?/1) do
      {:ok, hosts}
    else
      {:error, "allowed_egress_hosts must contain valid hostnames"}
    end
  end

  defp normalize_allowed_repos(nil), do: []
  defp normalize_allowed_repos([]), do: []

  defp normalize_allowed_repos(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_allowed_repos(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_allowed_repos(_), do: []

  defp default_allowed_egress_hosts do
    ["api.github.com", "api.anthropic.com", "api.openai.com"]
  end

  defp parse_non_neg_int(opts, runtime, key, default) do
    value = Keyword.get(opts, key, runtime[key])

    case parse_int(value) do
      nil -> {:ok, default}
      parsed when parsed >= 0 -> {:ok, parsed}
      _parsed -> {:error, "#{key} must be a non-negative integer"}
    end
  end

  defp parse_pos_int(opts, runtime, key, default) do
    value = Keyword.get(opts, key, runtime[key])

    case parse_int(value) do
      nil -> {:ok, default}
      parsed when parsed > 0 -> {:ok, parsed}
      _parsed -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp parse_optional_pos_int(opts, runtime, key) do
    value = Keyword.get(opts, key, runtime[key])

    case parse_int(value) do
      nil -> {:ok, nil}
      parsed when parsed > 0 -> {:ok, parsed}
      _parsed -> {:error, "#{key} must be nil or a positive integer"}
    end
  end

  defp parse_workdir(opts, runtime) do
    case Keyword.get(opts, :workdir, runtime[:workdir]) do
      nil ->
        {:ok, nil}

      workdir when is_binary(workdir) ->
        if Mom.Isolation.isolated_worktree?(workdir) do
          {:ok, workdir}
        else
          {:error, "workdir must reference an isolated git worktree"}
        end

      _other ->
        {:error, "workdir must reference an isolated git worktree"}
    end
  end

  defp parse_execution_profile(opts, runtime) do
    case Keyword.get(opts, :execution_profile, runtime[:execution_profile]) do
      nil ->
        {:ok, :test_relaxed}

      :test_relaxed ->
        {:ok, :test_relaxed}

      :staging_restricted ->
        {:ok, :staging_restricted}

      :production_hardened ->
        {:ok, :production_hardened}

      "test_relaxed" ->
        {:ok, :test_relaxed}

      "staging_restricted" ->
        {:ok, :staging_restricted}

      "production_hardened" ->
        {:ok, :production_hardened}

      _other ->
        {:error,
         "execution_profile must be :test_relaxed, :staging_restricted, or :production_hardened"}
    end
  end

  defp execution_policy(:test_relaxed, _workdir) do
    %{
      sandbox_mode: :unrestricted,
      command_allowlist: [],
      write_boundaries: []
    }
  end

  defp execution_policy(:staging_restricted, workdir) do
    %{
      sandbox_mode: :workspace_write,
      command_allowlist: ["codex"],
      write_boundaries: if(is_binary(workdir), do: [workdir], else: [])
    }
  end

  defp execution_policy(:production_hardened, workdir) do
    %{
      sandbox_mode: :read_only,
      command_allowlist: ["codex"],
      write_boundaries: if(is_binary(workdir), do: [workdir], else: [])
    }
  end

  defp validate_execution_policy(
         :test_relaxed,
         _llm_provider,
         _llm_cmd,
         _workdir,
         _open_pr,
         _merge_pr,
         _readiness_gate_approved
       ),
       do: :ok

  defp validate_execution_policy(
         :staging_restricted,
         llm_provider,
         llm_cmd,
         workdir,
         _open_pr,
         _merge_pr,
         _readiness_gate_approved
       ) do
    cond do
      not is_binary(workdir) ->
        {:error, "staging_restricted requires an isolated --workdir write boundary"}

      llm_provider != :codex ->
        {:error, "staging_restricted currently supports llm_provider=codex only"}

      not llm_cmd_binary_allowed?(llm_cmd, ["codex"]) ->
        {:error, "staging_restricted requires codex command allowlist compliance"}

      String.contains?(llm_cmd || "", "--yolo") ->
        {:error, "staging_restricted forbids --yolo execution"}

      not codex_workspace_write_sandbox?(llm_cmd) ->
        {:error, "staging_restricted requires codex sandbox mode workspace-write"}

      true ->
        :ok
    end
  end

  defp validate_execution_policy(
         :production_hardened,
         llm_provider,
         llm_cmd,
         workdir,
         open_pr,
         merge_pr,
         readiness_gate_approved
       ) do
    cond do
      not is_binary(workdir) ->
        {:error, "production_hardened requires an isolated --workdir write boundary"}

      llm_provider != :codex ->
        {:error, "production_hardened currently supports llm_provider=codex only"}

      not llm_cmd_binary_allowed?(llm_cmd, ["codex"]) ->
        {:error, "production_hardened requires codex command allowlist compliance"}

      String.contains?(llm_cmd || "", "--yolo") ->
        {:error, "production_hardened forbids --yolo execution"}

      not codex_read_only_sandbox?(llm_cmd) ->
        {:error, "production_hardened requires codex sandbox mode read-only"}

      (open_pr or merge_pr) and not readiness_gate_approved ->
        {:error, "production_hardened requires readiness gate approval for sensitive operations"}

      true ->
        :ok
    end
  end

  defp llm_cmd_binary_allowed?(llm_cmd, allowlist)
       when is_binary(llm_cmd) and is_list(allowlist) do
    case String.split(llm_cmd, ~r/\s+/, trim: true) do
      [binary | _] -> binary in allowlist
      [] -> false
    end
  end

  defp llm_cmd_binary_allowed?(_llm_cmd, _allowlist), do: false

  defp codex_workspace_write_sandbox?(llm_cmd) when is_binary(llm_cmd) do
    Regex.match?(~r/(^|\s)--sandbox(=|\s+)workspace-write(\s|$)/, llm_cmd)
  end

  defp codex_workspace_write_sandbox?(_llm_cmd), do: false

  defp codex_read_only_sandbox?(llm_cmd) when is_binary(llm_cmd) do
    Regex.match?(~r/(^|\s)--sandbox(=|\s+)read-only(\s|$)/, llm_cmd)
  end

  defp codex_read_only_sandbox?(_llm_cmd), do: false

  defp validate_policy_alignment(
         %__MODULE__{execution_profile: :staging_restricted} = config,
         expected
       ) do
    cond do
      config.write_boundaries != expected.write_boundaries ->
        {:error, "staging_restricted requires an isolated --workdir write boundary"}

      config.command_allowlist != expected.command_allowlist ->
        {:error, "staging_restricted requires codex command allowlist compliance"}

      config.sandbox_mode != expected.sandbox_mode ->
        {:error, "staging_restricted requires codex sandbox mode workspace-write"}

      true ->
        :ok
    end
  end

  defp validate_policy_alignment(
         %__MODULE__{execution_profile: :production_hardened} = config,
         expected
       ) do
    cond do
      config.write_boundaries != expected.write_boundaries ->
        {:error, "production_hardened requires an isolated --workdir write boundary"}

      config.command_allowlist != expected.command_allowlist ->
        {:error, "production_hardened requires codex command allowlist compliance"}

      config.sandbox_mode != expected.sandbox_mode ->
        {:error, "production_hardened requires codex sandbox mode read-only"}

      true ->
        :ok
    end
  end

  defp parse_overflow_policy(opts, runtime) do
    case Keyword.get(opts, :overflow_policy, runtime[:overflow_policy]) do
      nil -> {:ok, :drop_newest}
      :drop_newest -> {:ok, :drop_newest}
      :drop_oldest -> {:ok, :drop_oldest}
      "drop_newest" -> {:ok, :drop_newest}
      "drop_oldest" -> {:ok, :drop_oldest}
      _other -> {:error, "overflow_policy must be :drop_newest or :drop_oldest"}
    end
  end

  defp parse_durable_queue_path(opts, runtime) do
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

  defp parse_observability_backend(opts, runtime) do
    case Keyword.get(opts, :observability_backend, runtime[:observability_backend]) do
      nil -> {:ok, :none}
      :none -> {:ok, :none}
      :prometheus -> {:ok, :prometheus}
      "none" -> {:ok, :none}
      "prometheus" -> {:ok, :prometheus}
      _other -> {:error, "observability_backend must be :none or :prometheus"}
    end
  end

  defp parse_observability_export_path(opts, runtime, :none) do
    {:ok, Keyword.get(opts, :observability_export_path, runtime[:observability_export_path])}
  end

  defp parse_observability_export_path(opts, runtime, :prometheus) do
    case Keyword.get(opts, :observability_export_path, runtime[:observability_export_path]) do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _other ->
        {:error,
         "observability_export_path is required when observability_backend is :prometheus"}
    end
  end

  defp parse_ratio(opts, runtime, key, default) do
    value = Keyword.get(opts, key, runtime[key])

    case parse_float(value) do
      nil ->
        {:ok, default}

      parsed when parsed >= 0.0 and parsed <= 1.0 ->
        {:ok, parsed}

      _parsed ->
        {:error, "#{key} must be between 0.0 and 1.0"}
    end
  end

  defp parse_and_validate_github_repo(opts, runtime, allowed_github_repos, actor_id) do
    github_repo = Keyword.get(opts, :github_repo) || runtime[:github_repo]

    cond do
      allowed_github_repos == [] ->
        {:ok, github_repo}

      is_nil(github_repo) ->
        {:error, "github_repo must be set when allowed_github_repos is configured"}

      github_repo in allowed_github_repos ->
        {:ok, github_repo}

      true ->
        :ok =
          Audit.emit(:github_repo_disallowed, %{
            repo: github_repo,
            actor_id: actor_id,
            allowed_repos: allowed_github_repos
          })

        {:error, "github_repo is not allowed"}
    end
  end

  defp parse_branch_name_prefix(opts, runtime) do
    prefix = Keyword.get(opts, :branch_name_prefix, runtime[:branch_name_prefix]) || "mom"

    if valid_branch_prefix?(prefix) do
      {:ok, prefix}
    else
      {:error, "branch_name_prefix is not a valid git branch prefix"}
    end
  end

  defp parse_github_base_branch(opts, runtime) do
    base_branch = Keyword.get(opts, :github_base_branch, runtime[:github_base_branch]) || "main"

    if valid_branch_prefix?(base_branch) do
      {:ok, base_branch}
    else
      {:error, "github_base_branch is not a valid git branch name"}
    end
  end

  defp parse_protected_branches(opts, runtime, github_base_branch) do
    parsed =
      opts
      |> Keyword.get(:protected_branches, runtime[:protected_branches])
      |> normalize_allowed_repos()
      |> case do
        [] -> [github_base_branch]
        list -> list
      end
      |> Enum.uniq()

    if Enum.all?(parsed, &valid_branch_prefix?/1) do
      {:ok, parsed}
    else
      {:error, "protected_branches must contain valid git branch names"}
    end
  end

  defp parse_readiness_gate_approved(opts, runtime) do
    case Keyword.get(opts, :readiness_gate_approved, runtime[:readiness_gate_approved] || false) do
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, "readiness_gate_approved must be a boolean"}
    end
  end

  defp parse_open_pr(opts, runtime, opts_for_profile) do
    default =
      case Keyword.get(opts_for_profile, :execution_profile) do
        :production_hardened -> false
        _ -> true
      end

    parse_boolean_opt(opts, runtime, :open_pr, default, "open_pr must be a boolean")
  end

  defp parse_merge_pr(opts, runtime) do
    parse_boolean_opt(opts, runtime, :merge_pr, false, "merge_pr must be a boolean")
  end

  defp parse_boolean_opt(opts, runtime, key, default, error_message) do
    case Keyword.get(opts, key, runtime[key]) do
      nil -> {:ok, default}
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, error_message}
    end
  end

  defp valid_branch_prefix?(prefix) when is_binary(prefix) do
    trimmed = String.trim(prefix)

    trimmed == prefix and
      trimmed != "" and
      Regex.match?(~r/^[0-9A-Za-z._\/-]+$/, trimmed) and
      not String.contains?(trimmed, ["..", "@{"]) and
      not String.starts_with?(trimmed, ["/", ".", "-"]) and
      not String.ends_with?(trimmed, ["/", ".", ".lock"]) and
      Enum.all?(String.split(trimmed, "/"), &valid_branch_segment?/1)
  end

  defp valid_branch_prefix?(_), do: false

  defp valid_branch_segment?(segment) do
    segment != "" and
      segment != "." and
      segment != ".." and
      not String.starts_with?(segment, ".") and
      not String.ends_with?(segment, ".lock")
  end

  defp parse_actor_id(opts, runtime) do
    case Keyword.get(opts, :actor_id) || runtime[:actor_id] || System.get_env("GITHUB_ACTOR") do
      nil -> "mom"
      actor when is_binary(actor) -> String.trim(actor)
      actor -> to_string(actor) |> String.trim()
    end
  end

  defp validate_actor_identity(actor_id, github_token, allowed_actor_ids) do
    cond do
      actor_id == "" ->
        {:error, "actor_id must not be empty"}

      is_binary(github_token) and String.trim(github_token) != "" and allowed_actor_ids == [] ->
        {:error, "allowed_actor_ids must be set when github_token is configured"}

      allowed_actor_ids != [] and actor_id not in allowed_actor_ids ->
        {:error, "actor_id is not allowed"}

      is_binary(github_token) and String.trim(github_token) != "" and
          not machine_actor_identity?(actor_id) ->
        {:error, "actor_id must be a dedicated machine identity"}

      true ->
        :ok
    end
  end

  defp machine_actor_identity?(actor_id) when is_binary(actor_id) do
    normalized = String.downcase(actor_id)

    String.ends_with?(normalized, "[bot]") or
      String.contains?(normalized, "-bot") or
      String.contains?(normalized, "_bot") or
      String.starts_with?(normalized, "app/")
  end

  defp machine_actor_identity?(_), do: false

  defp validate_automated_pr_readiness(
         open_pr,
         github_token,
         github_repo,
         readiness_gate_approved,
         actor_id,
         github_base_branch,
         protected_branches
       ) do
    if automated_pr_flow?(open_pr, github_token, github_repo) do
      cond do
        not readiness_gate_approved ->
          emit_readiness_blocked(github_repo, actor_id, github_base_branch, protected_branches,
            reason: :readiness_gate_not_approved
          )

          {:error, "readiness_gate_approved must be true before enabling automated PR creation"}

        github_base_branch not in protected_branches ->
          emit_readiness_blocked(github_repo, actor_id, github_base_branch, protected_branches,
            reason: :base_branch_not_protected
          )

          {:error, "github_base_branch must be included in protected_branches"}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp automated_pr_flow?(open_pr, github_token, github_repo) do
    open_pr and token_present?(github_token) and value_present?(github_repo)
  end

  defp token_present?(token) when is_binary(token), do: String.trim(token) != ""
  defp token_present?(_token), do: false

  defp value_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp value_present?(_value), do: false

  defp emit_readiness_blocked(repo, actor_id, github_base_branch, protected_branches, opts) do
    :ok =
      Audit.emit(:automated_pr_readiness_blocked, %{
        repo: repo,
        actor_id: actor_id,
        base_branch: github_base_branch,
        protected_branches: protected_branches,
        reason: Keyword.fetch!(opts, :reason)
      })
  end

  defp validate_required_egress_hosts(llm_provider, llm_api_url, allowed_egress_hosts) do
    with {:ok, required_llm_host} <- required_llm_host(llm_provider, llm_api_url),
         :ok <- ensure_host_allowed("api.github.com", allowed_egress_hosts),
         :ok <- maybe_ensure_host_allowed(required_llm_host, allowed_egress_hosts) do
      :ok
    end
  end

  defp required_llm_host(:api_anthropic, nil), do: {:ok, "api.anthropic.com"}
  defp required_llm_host(:api_openai, nil), do: {:ok, "api.openai.com"}
  defp required_llm_host(:api_anthropic, url), do: parse_url_host(url)
  defp required_llm_host(:api_openai, url), do: parse_url_host(url)
  defp required_llm_host(_other, nil), do: {:ok, nil}
  defp required_llm_host(_other, url), do: parse_url_host(url)

  defp parse_url_host(url) when is_binary(url) do
    uri = URI.parse(url)

    if valid_host?(uri.host) do
      {:ok, String.downcase(uri.host)}
    else
      {:error, "llm_api_url must be a valid URL with a host"}
    end
  end

  defp parse_url_host(_), do: {:error, "llm_api_url must be a valid URL with a host"}

  defp maybe_ensure_host_allowed(nil, _allowed_hosts), do: :ok

  defp maybe_ensure_host_allowed(host, allowed_hosts),
    do: ensure_host_allowed(host, allowed_hosts)

  defp ensure_host_allowed(host, allowed_hosts) do
    if host in allowed_hosts do
      :ok
    else
      {:error, "allowed_egress_hosts is missing required host #{host}"}
    end
  end

  defp valid_host?(host) when is_binary(host) do
    trimmed = String.trim(host)

    trimmed == host and Regex.match?(~r/^[A-Za-z0-9.-]+$/, trimmed) and
      String.contains?(trimmed, ".")
  end

  defp valid_host?(_), do: false
end
