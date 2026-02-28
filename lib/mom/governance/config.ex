defmodule Mom.Config do
  @moduledoc false

  # TODO(architecture): Split this module into clear boundaries:
  # 1) parsing + validation of config inputs,
  # 2) policy gate evaluation,
  # 3) side effects (startup pruning, attestations, telemetry/audit emissions).
  # `from_opts/1` currently mixes all three concerns.

  alias Mom.{Audit, Isolation}
  alias Mom.GitHubCredentialEvidence

  alias Mom.Governance.Configs.{
    Compliance,
    Diagnostics,
    Governance,
    LLM,
    Observability,
    Pipeline,
    Runtime
  }

  alias Mom.Governance.Gates.Protocols.Evaluator, as: GateEvaluator

  require Logger

  @type llm_provider :: :claude_code | :codex | :api_anthropic | :api_openai

  defstruct [
    :runtime,
    :llm,
    :diagnostics,
    :pipeline,
    :governance,
    :compliance,
    :observability
  ]

  @type t :: %__MODULE__{
          runtime: Runtime.t(),
          llm: LLM.t(),
          diagnostics: Diagnostics.t(),
          pipeline: Pipeline.t(),
          governance: Governance.t(),
          compliance: Compliance.t(),
          observability: Observability.t()
        }

  @spec from_opts(keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_opts(opts) do
    repo = Keyword.get(opts, :repo)
    runtime_env = Application.get_all_env(:mom)
    runtime = merge_runtime_defaults(runtime_env, runtime_env[:defaults] || [])
    redact_keys = Compliance.normalize_redact_keys(Keyword.get(opts, :redact_keys) || runtime[:redact_keys])
    llm_provider = Keyword.get(opts, :llm_provider, runtime[:llm_provider])
    llm_cmd_override = Keyword.get(opts, :llm_cmd) || runtime[:llm_cmd]
    llm_api_url = Keyword.get(opts, :llm_api_url) || runtime[:llm_api_url]

    cond do
      is_nil(repo) ->
        {:error, "repo is required"}

      true ->
        github_token = secret_from_opts_or_env(opts, runtime, :github_token, "MOM_GITHUB_TOKEN")
        llm_api_key = secret_from_opts_or_env(opts, runtime, :llm_api_key, "MOM_LLM_API_KEY")

        startup_attestation_signing_key =
          secret_from_opts_or_env(
            opts,
            runtime,
            :startup_attestation_signing_key,
            "MOM_STARTUP_ATTESTATION_SIGNING_KEY"
          )

        actor_id = Governance.parse_actor_id(opts, runtime)

        with :ok <- validate_toolchain_prerequisites(opts, runtime),
             {:ok, temp_worktree_retention_seconds} <-
               parse_non_neg_int(
                 opts,
                 runtime,
                 :temp_worktree_retention_seconds,
                 runtime[:temp_worktree_retention_seconds]
               ),
             {:ok, temp_worktree_keep_latest} <-
               parse_non_neg_int(
                 opts,
                 runtime,
                 :temp_worktree_keep_latest,
                 runtime[:temp_worktree_keep_latest]
               ),
             {:ok, temp_worktree_prune_summary} <-
               maybe_prune_ephemeral_tmp_worktrees(
                 temp_worktree_retention_seconds,
                 temp_worktree_keep_latest
               ),
             {:ok, temp_worktree_max_active} <-
               parse_pos_int(
                 opts,
                 runtime,
                 :temp_worktree_max_active,
                 runtime[:temp_worktree_max_active]
               ),
             {:ok, temp_worktree_alert_utilization_threshold} <-
               parse_ratio(
                 opts,
                 runtime,
                 :temp_worktree_alert_utilization_threshold,
                 runtime[:temp_worktree_alert_utilization_threshold]
               ),
             :ok <-
               enforce_temp_worktree_capacity_guardrails(
                 temp_worktree_prune_summary,
                 temp_worktree_max_active,
                 temp_worktree_alert_utilization_threshold,
                 actor_id
               ),
             {:ok, max_concurrency} <-
               parse_non_neg_int(opts, runtime, :max_concurrency, runtime[:max_concurrency]),
             {:ok, queue_max_size} <-
               parse_pos_int(opts, runtime, :queue_max_size, runtime[:queue_max_size]),
             {:ok, tenant_queue_max_size} <-
               parse_optional_pos_int(opts, runtime, :tenant_queue_max_size),
             {:ok, llm_spend_cap_cents_per_hour} <-
               parse_optional_pos_int(opts, runtime, :llm_spend_cap_cents_per_hour),
             {:ok, llm_call_cost_cents} <-
               parse_non_neg_int(
                 opts,
                 runtime,
                 :llm_call_cost_cents,
                 runtime[:llm_call_cost_cents]
               ),
             {:ok, llm_token_cap_per_hour} <-
               parse_optional_pos_int(opts, runtime, :llm_token_cap_per_hour),
             {:ok, llm_tokens_per_call_estimate} <-
               parse_non_neg_int(
                 opts,
                 runtime,
                 :llm_tokens_per_call_estimate,
                 runtime[:llm_tokens_per_call_estimate]
               ),
             {:ok, test_spend_cap_cents_per_hour} <-
               parse_optional_pos_int(opts, runtime, :test_spend_cap_cents_per_hour),
             {:ok, test_run_cost_cents} <-
               parse_non_neg_int(
                 opts,
                 runtime,
                 :test_run_cost_cents,
                 runtime[:test_run_cost_cents]
               ),
             {:ok, job_timeout_ms} <-
               parse_pos_int(opts, runtime, :job_timeout_ms, runtime[:job_timeout_ms]),
             {:ok, execution_watchdog_enabled} <-
               Pipeline.parse_execution_watchdog_enabled(opts, runtime),
             {:ok, execution_watchdog_orphan_grace_ms} <-
               parse_non_neg_int(
                 opts,
                 runtime,
                 :execution_watchdog_orphan_grace_ms,
                 runtime[:execution_watchdog_orphan_grace_ms]
               ),
             {:ok, overflow_policy} <- Pipeline.parse_overflow_policy(opts, runtime),
             {:ok, durable_queue_path} <- Pipeline.parse_durable_queue_path(opts, runtime),
             {:ok, audit_retention_days} <-
               parse_pos_int(opts, runtime, :audit_retention_days, runtime[:audit_retention_days]),
             {:ok, soc2_evidence_path} <- Compliance.parse_soc2_evidence_path(opts, runtime),
             {:ok, pii_handling_policy} <- Compliance.parse_pii_handling_policy(opts, runtime),
             {:ok, observability_backend} <- Observability.parse_observability_backend(opts, runtime),
             {:ok, observability_export_path} <-
               Observability.parse_observability_export_path(opts, runtime, observability_backend),
             {:ok, observability_export_interval_ms} <-
               parse_pos_int(
                 opts,
                 runtime,
                 :observability_export_interval_ms,
                 runtime[:observability_export_interval_ms]
               ),
             {:ok, slo_queue_depth_threshold} <-
               parse_pos_int(
                 opts,
                 runtime,
                 :slo_queue_depth_threshold,
                 runtime[:slo_queue_depth_threshold]
               ),
             {:ok, slo_drop_rate_threshold} <-
               parse_ratio(
                 opts,
                 runtime,
                 :slo_drop_rate_threshold,
                 runtime[:slo_drop_rate_threshold]
               ),
             {:ok, slo_failure_rate_threshold} <-
               parse_ratio(
                 opts,
                 runtime,
                 :slo_failure_rate_threshold,
                 runtime[:slo_failure_rate_threshold]
               ),
             {:ok, slo_latency_p95_ms_threshold} <-
               parse_pos_int(
                 opts,
                 runtime,
                 :slo_latency_p95_ms_threshold,
                 runtime[:slo_latency_p95_ms_threshold]
               ),
             {:ok, sla_triage_latency_p95_ms_target} <-
               parse_pos_int(
                 opts,
                 runtime,
                 :sla_triage_latency_p95_ms_target,
                 runtime[:sla_triage_latency_p95_ms_target]
               ),
             {:ok, sla_queue_durability_target} <-
               parse_ratio(
                 opts,
                 runtime,
                 :sla_queue_durability_target,
                 runtime[:sla_queue_durability_target]
               ),
             {:ok, sla_pr_turnaround_p95_ms_target} <-
               parse_pos_int(
                 opts,
                 runtime,
                 :sla_pr_turnaround_p95_ms_target,
                 runtime[:sla_pr_turnaround_p95_ms_target]
               ),
             {:ok, error_budget_triage_latency_overage_rate} <-
               parse_ratio(
                 opts,
                 runtime,
                 :error_budget_triage_latency_overage_rate,
                 runtime[:error_budget_triage_latency_overage_rate]
               ),
             {:ok, error_budget_queue_loss_rate} <-
               parse_ratio(
                 opts,
                 runtime,
                 :error_budget_queue_loss_rate,
                 runtime[:error_budget_queue_loss_rate]
               ),
             {:ok, error_budget_pr_turnaround_overage_rate} <-
               parse_ratio(
                 opts,
                 runtime,
                 :error_budget_pr_turnaround_overage_rate,
                 runtime[:error_budget_pr_turnaround_overage_rate]
               ),
             {:ok, allowed_github_repos} <- Governance.parse_allowed_github_repos(opts, runtime),
             {:ok, allowed_actor_ids} <- Governance.parse_allowed_actor_ids(opts, runtime),
             {:ok, branch_name_prefix} <- Governance.parse_branch_name_prefix(opts, runtime),
             {:ok, allowed_egress_hosts} <- Governance.parse_allowed_egress_hosts(opts, runtime),
             {:ok, github_credential_scopes} <- Compliance.parse_github_credential_scopes(opts, runtime),
             {:ok, github_live_permission_verification} <-
               Compliance.parse_github_live_permission_verification(opts, runtime),
             :ok <-
               Governance.validate_required_egress_hosts(
                 llm_provider,
                 llm_api_url,
                 allowed_egress_hosts
               ),
             {:ok, github_base_branch} <- Governance.parse_github_base_branch(opts, runtime),
             {:ok, protected_branches} <-
               Governance.parse_protected_branches(opts, runtime, github_base_branch),
             {:ok, readiness_gate_approved} <- Governance.parse_readiness_gate_approved(opts, runtime),
             {:ok, incident_to_pr_canary_artifact_path} <-
               parse_incident_to_pr_canary_artifact_path(opts, runtime),
             {:ok, incident_to_pr_canary_max_age_seconds} <-
               parse_incident_to_pr_canary_max_age_seconds(opts, runtime),
             {:ok, merge_pr} <- Governance.parse_merge_pr(opts, runtime),
             {:ok, workdir} <- parse_workdir(opts, runtime),
             {:ok, execution_profile} <- Governance.parse_execution_profile(opts, runtime),
             {:ok, test_command_profile} <- Diagnostics.parse_test_command_profile(opts, runtime),
             {:ok, open_pr} <- Governance.parse_open_pr(opts, runtime, execution_profile: execution_profile),
             llm_cmd <- LLM.default_cmd(llm_provider, llm_cmd_override, execution_profile),
             policy <- Governance.execution_policy(execution_profile, workdir),
             :ok <-
               Diagnostics.validate_test_command_profile_policy(
                 test_command_profile,
                 execution_profile
               ),
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
             :ok <- validate_actor_identity(actor_id, github_token, allowed_actor_ids, runtime),
             :ok <-
               validate_github_credential_permissions(
                 github_token,
                 github_credential_scopes,
                 github_live_permission_verification,
                 startup_attestation_signing_key,
                 open_pr,
                 merge_pr,
                 actor_id,
                 Keyword.get(opts, :github_repo) || runtime[:github_repo],
                 allowed_egress_hosts
               ),
             :ok <-
               validate_automated_pr_readiness(
                 open_pr,
                 github_token,
                 Keyword.get(opts, :github_repo) || runtime[:github_repo],
                 readiness_gate_approved,
                 execution_profile,
                 incident_to_pr_canary_artifact_path,
                 incident_to_pr_canary_max_age_seconds,
                 startup_attestation_signing_key,
                 actor_id,
                 github_base_branch,
                 protected_branches,
                 runtime
               ),
             {:ok, github_repo} <-
               parse_and_validate_github_repo(opts, runtime, allowed_github_repos, actor_id),
             :ok <-
               attest_execution_profile_baseline(
                 execution_profile,
                 llm_provider,
                 llm_cmd,
                 policy,
                 workdir,
                 open_pr,
                 merge_pr,
                 readiness_gate_approved,
                 test_command_profile,
                 actor_id,
                 repo,
                 github_repo,
                 startup_attestation_signing_key
               ) do
          {:ok,
           %__MODULE__{
             runtime: %Runtime{
               repo: repo,
               node: Keyword.get(opts, :node),
               cookie: Keyword.get(opts, :cookie),
               mode: Keyword.get(opts, :mode, runtime[:mode]),
               workdir: workdir,
               poll_interval_ms: Keyword.get(opts, :poll_interval_ms, runtime[:poll_interval_ms]),
               min_level: Keyword.get(opts, :min_level, runtime[:min_level]),
               dry_run: Keyword.get(opts, :dry_run, runtime[:dry_run])
             },
             llm: %LLM{
               provider: llm_provider,
               cmd: llm_cmd,
               api_key: llm_api_key,
               api_url: llm_api_url,
               model: Keyword.get(opts, :llm_model) || runtime[:llm_model],
               rate_limit_per_hour:
                 parse_int(
                   Keyword.get(opts, :llm_rate_limit_per_hour) ||
                     runtime[:llm_rate_limit_per_hour]
                 ),
               spend_cap_cents_per_hour: llm_spend_cap_cents_per_hour,
               call_cost_cents: llm_call_cost_cents,
               token_cap_per_hour: llm_token_cap_per_hour,
               tokens_per_call_estimate: llm_tokens_per_call_estimate
             },
             diagnostics: %Diagnostics{
               triage_on_diagnostics:
                 Keyword.get(opts, :triage_on_diagnostics, runtime[:triage_on_diagnostics]),
               triage_mode: Keyword.get(opts, :triage_mode, runtime[:triage_mode]),
               diag_run_queue_mult:
                 Keyword.get(opts, :diag_run_queue_mult, runtime[:diag_run_queue_mult]),
               diag_mem_high_bytes:
                 Keyword.get(opts, :diag_mem_high_bytes, runtime[:diag_mem_high_bytes]),
               diag_cooldown_ms: Keyword.get(opts, :diag_cooldown_ms, runtime[:diag_cooldown_ms]),
               issue_rate_limit_per_hour:
                 parse_int(
                   Keyword.get(opts, :issue_rate_limit_per_hour) ||
                     runtime[:issue_rate_limit_per_hour]
                 ),
               issue_dedupe_window_ms:
                 parse_int(
                   Keyword.get(opts, :issue_dedupe_window_ms) || runtime[:issue_dedupe_window_ms]
                 ),
               test_spend_cap_cents_per_hour: test_spend_cap_cents_per_hour,
               test_run_cost_cents: test_run_cost_cents,
               test_command_profile: test_command_profile
             },
             pipeline: %Pipeline{
               max_concurrency: max_concurrency,
               queue_max_size: queue_max_size,
               tenant_queue_max_size: tenant_queue_max_size,
               job_timeout_ms: job_timeout_ms,
               overflow_policy: overflow_policy,
               durable_queue_path: durable_queue_path,
               execution_watchdog_enabled: execution_watchdog_enabled,
               execution_watchdog_orphan_grace_ms: execution_watchdog_orphan_grace_ms,
               temp_worktree_max_active: temp_worktree_max_active,
               temp_worktree_alert_utilization_threshold:
                 temp_worktree_alert_utilization_threshold
             },
             governance: %Governance{
               execution_profile: execution_profile,
               sandbox_mode: policy.sandbox_mode,
               command_allowlist: policy.command_allowlist,
               write_boundaries: policy.write_boundaries,
               open_pr: open_pr,
               merge_pr: merge_pr,
               readiness_gate_approved: readiness_gate_approved,
               allowed_github_repos: allowed_github_repos,
               allowed_actor_ids: allowed_actor_ids,
               github_repo: github_repo,
               github_base_branch: github_base_branch,
               protected_branches: protected_branches,
               actor_id: actor_id,
               allowed_egress_hosts: allowed_egress_hosts,
               branch_name_prefix: branch_name_prefix,
               governance_gates: runtime[:governance_gates]
             },
             compliance: %Compliance{
               audit_retention_days: audit_retention_days,
               soc2_evidence_path: soc2_evidence_path,
               pii_handling_policy: pii_handling_policy,
               redact_keys: redact_keys,
               git_ssh_command: Keyword.get(opts, :git_ssh_command) || runtime[:git_ssh_command],
               github_token: github_token,
               github_credential_scopes: github_credential_scopes,
               github_live_permission_verification: github_live_permission_verification
             },
             observability: %Observability{
               backend: observability_backend,
               export_path: observability_export_path,
               export_interval_ms: observability_export_interval_ms,
               slo_queue_depth_threshold: slo_queue_depth_threshold,
               slo_drop_rate_threshold: slo_drop_rate_threshold,
               slo_failure_rate_threshold: slo_failure_rate_threshold,
               slo_latency_p95_ms_threshold: slo_latency_p95_ms_threshold,
               sla_triage_latency_p95_ms_target: sla_triage_latency_p95_ms_target,
               sla_queue_durability_target: sla_queue_durability_target,
               sla_pr_turnaround_p95_ms_target: sla_pr_turnaround_p95_ms_target,
               error_budget_triage_latency_overage_rate: error_budget_triage_latency_overage_rate,
               error_budget_queue_loss_rate: error_budget_queue_loss_rate,
               error_budget_pr_turnaround_overage_rate: error_budget_pr_turnaround_overage_rate
             }
           }}
        end
    end
  end

  defp merge_runtime_defaults(runtime, defaults) when is_list(defaults) do
    Enum.reduce(defaults, runtime, fn {key, value}, acc ->
      if Keyword.has_key?(acc, key) do
        acc
      else
        Keyword.put(acc, key, value)
      end
    end)
  end

  defp evaluate_configured_gate(runtime, gate_key, attrs) when is_map(attrs) do
    with {:ok, template} <- configured_gate_template(runtime, gate_key) do
      gate_input = hydrate_gate_template(template, attrs)
      {:ok, GateEvaluator.evaluate(gate_input)}
    end
  end

  defp configured_gate_template(runtime, gate_key) do
    case runtime[:governance_gates] do
      gates when is_list(gates) ->
        case Keyword.fetch(gates, gate_key) do
          {:ok, template} when is_struct(template) ->
            {:ok, template}

          {:ok, _other} ->
            {:error, "governance gate #{gate_key} must be configured as a struct"}

          :error ->
            {:error, "missing configured governance gate #{gate_key}"}
        end

      gates when is_map(gates) ->
        case Map.get(gates, gate_key) do
          template when is_struct(template) ->
            {:ok, template}

          nil ->
            {:error, "missing configured governance gate #{gate_key}"}

          _other ->
            {:error, "governance gate #{gate_key} must be configured as a struct"}
        end

      _other ->
        {:error, "governance_gates must be configured as a keyword list or map"}
    end
  end

  defp hydrate_gate_template(template, attrs) do
    keys = Map.keys(template) -- [:__struct__]
    merged = Map.merge(Map.from_struct(template), Map.take(attrs, keys))
    struct(template.__struct__, merged)
  end

  defp validate_toolchain_prerequisites(opts, runtime) do
    with {:ok, minimum_node_major} <- required_node_major(runtime),
         {:ok, required_otp_version} <- required_otp_version(runtime),
         {:ok, required_elixir_version} <- required_elixir_version(runtime),
         {:ok, node_version} <- detect_node_version(opts, runtime),
         :ok <- validate_node_version(node_version, minimum_node_major),
         {:ok, otp_version} <- detect_otp_version(opts, runtime),
         :ok <- validate_otp_version(otp_version, required_otp_version),
         {:ok, elixir_version} <- detect_elixir_version(opts, runtime),
         :ok <- validate_elixir_version(elixir_version, required_elixir_version) do
      :ok
    end
  end

  defp required_node_major(runtime) do
    case parse_int(runtime[:required_node_major]) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      _ ->
        {:error, "required_node_major must be a positive integer"}
    end
  end

  defp required_otp_version(runtime) do
    case runtime[:required_otp_version] do
      value when is_binary(value) and value != "" ->
        {:ok, String.trim(value)}

      _ ->
        {:error, "required_otp_version must be a non-empty string"}
    end
  end

  defp required_elixir_version(runtime) do
    case runtime[:required_elixir_version] do
      value when is_binary(value) and value != "" ->
        {:ok, String.trim(value)}

      _ ->
        {:error, "required_elixir_version must be a non-empty string"}
    end
  end

  defp detect_node_version(opts, runtime) do
    case Keyword.get(opts, :toolchain_node_version_override) ||
           runtime[:toolchain_node_version_override] ||
           System.get_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE") do
      nil -> run_node_version_command()
      value -> {:ok, normalize_version_string(value)}
    end
  end

  defp run_node_version_command do
    case System.cmd("node", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, normalize_version_string(output)}

      {output, status} ->
        {:error,
         "node --version failed with exit status #{status}: #{normalize_version_string(output)}"}
    end
  rescue
    _error ->
      {:error, "node executable is required and must be available in PATH"}
  end

  defp validate_node_version(version, minimum_major) do
    with {:ok, %{major: parsed_major, display_version: display_version}} <-
           parse_major_version(version, "node --version") do
      if parsed_major >= minimum_major do
        :ok
      else
        {:error, "node --version must be >= #{minimum_major}.x; found #{display_version}"}
      end
    end
  end

  defp detect_otp_version(opts, runtime) do
    case Keyword.get(opts, :toolchain_otp_version_override) ||
           runtime[:toolchain_otp_version_override] ||
           System.get_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE") do
      nil -> read_otp_version_file()
      value -> {:ok, normalize_version_string(value)}
    end
  end

  defp read_otp_version_file do
    root = :code.root_dir() |> to_string()
    otp_release = :erlang.system_info(:otp_release) |> to_string()
    otp_version_path = Path.join([root, "releases", otp_release, "OTP_VERSION"])

    case File.read(otp_version_path) do
      {:ok, value} ->
        {:ok, normalize_version_string(value)}

      {:error, reason} ->
        {:error,
         "erlang/otp patch version could not be determined from #{otp_version_path}: #{inspect(reason)}"}
    end
  end

  defp validate_otp_version(actual_version, required_version) do
    if actual_version == required_version do
      :ok
    else
      {:error, "erlang/otp version must be #{required_version}; found #{actual_version}"}
    end
  end

  defp detect_elixir_version(opts, runtime) do
    case Keyword.get(opts, :toolchain_elixir_version_override) ||
           runtime[:toolchain_elixir_version_override] ||
           System.get_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE") do
      nil -> {:ok, System.version()}
      value -> {:ok, normalize_version_string(value)}
    end
  end

  defp validate_elixir_version(actual_version, required_version) do
    with {:ok, required} <- Version.parse(required_version),
         {:ok, parsed} <- Version.parse(actual_version),
         true <- required.pre == [],
         true <- parsed.pre == [] do
      if parsed.major == required.major and parsed.minor == required.minor and
           parsed.patch == required.patch do
        :ok
      else
        {:error, "elixir version must be stable #{required_version}; found #{actual_version}"}
      end
    else
      _ ->
        {:error, "elixir version must be stable #{required_version}; found #{actual_version}"}
    end
  end

  defp parse_major_version(version, label) do
    version_candidate =
      version
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.find(&Regex.match?(~r/^v?\d+(?:\.\d+){1,2}$/, &1))
      |> case do
        nil -> String.trim(version)
        line -> line
      end

    case Regex.run(~r/^(v?(\d+)(?:\.\d+){1,2})$/, version_candidate) do
      [_full_match, matched_version, major] ->
        {parsed, _rest} = Integer.parse(major)
        {:ok, %{major: parsed, display_version: matched_version}}

      _ ->
        {:error, "#{label} returned an unparseable version: #{version}"}
    end
  end

  defp normalize_version_string(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp maybe_prune_ephemeral_tmp_worktrees(retention_seconds, keep_latest)
       when is_integer(retention_seconds) and retention_seconds >= 0 and is_integer(keep_latest) and
              keep_latest >= 0 do
    tmp_root = System.tmp_dir!()

    case Isolation.prune_ephemeral_tmp_worktrees(tmp_root,
           retention_seconds: retention_seconds,
           keep_latest: keep_latest
         ) do
      {:ok, summary} ->
        {:ok, summary}

      {:error, reason} ->
        Logger.warning(
          "mom: failed pruning ephemeral temp worktrees in #{tmp_root}: #{inspect(reason)}"
        )

        {:ok, %{candidates: 0, kept: [], removed: [], failed: []}}
    end
  rescue
    exception ->
      Logger.warning(
        "mom: failed resolving temp directory for worktree pruning: #{inspect(exception)}"
      )

      {:ok, %{candidates: 0, kept: [], removed: [], failed: []}}
  end

  defp enforce_temp_worktree_capacity_guardrails(
         prune_summary,
         max_active,
         alert_utilization_threshold,
         actor_id
       )
       when is_map(prune_summary) and is_integer(max_active) and max_active > 0 and
              is_float(alert_utilization_threshold) do
    active_worktrees =
      (prune_summary[:kept] || [])
      |> length()
      |> Kernel.+(length(prune_summary[:failed] || []))

    pruned_worktrees = length(prune_summary[:removed] || [])
    utilization = active_worktrees / max_active

    metadata = %{
      actor_id: actor_id,
      active_worktrees: active_worktrees,
      max_active_worktrees: max_active,
      utilization: utilization,
      alert_utilization_threshold: alert_utilization_threshold,
      pruned_worktrees: pruned_worktrees,
      prune_failures: length(prune_summary[:failed] || [])
    }

    :ok = Audit.emit(:temp_worktree_capacity_observed, metadata)

    if utilization >= alert_utilization_threshold do
      :telemetry.execute(
        [:mom, :alert, :temp_worktree_capacity],
        %{count: 1},
        Map.put(metadata, :status, :alert)
      )

      :ok = Audit.emit(:temp_worktree_capacity_alert, metadata)
    end

    if active_worktrees > max_active do
      :telemetry.execute(
        [:mom, :alert, :temp_worktree_capacity],
        %{count: 1},
        metadata
        |> Map.put(:status, :blocked)
        |> Map.put(:exceeded_by, active_worktrees - max_active)
      )

      :ok = Audit.emit(:temp_worktree_capacity_blocked, metadata)
      {:error, "temp_worktree_max_active exceeded: #{active_worktrees}/#{max_active}"}
    else
      :ok
    end
  end

  @spec validate_runtime_policy(t()) :: :ok | {:error, String.t()}
  def validate_runtime_policy(%__MODULE__{governance: %{execution_profile: :test_relaxed}}),
    do: :ok

  def validate_runtime_policy(%__MODULE__{} = config) do
    policy =
      Governance.execution_policy(
        config.governance.execution_profile,
        config.runtime.workdir
      )

    with :ok <- Governance.validate_policy_alignment(config.governance, policy),
         :ok <-
           validate_execution_policy(
             config.governance.execution_profile,
             config.llm.provider,
             config.llm.cmd,
             config.runtime.workdir,
             config.governance.open_pr,
             config.governance.merge_pr,
             config.governance.readiness_gate_approved
           ),
         :ok <-
           Diagnostics.validate_test_command_profile_policy(
             config.diagnostics.test_command_profile,
             config.governance.execution_profile
           ) do
      :ok
    end
  end

  @spec resolve_test_command_profile(Diagnostics.test_command_profile()) ::
          {:ok, Diagnostics.test_command_profile_spec()}
          | {:error, String.t()}
  def resolve_test_command_profile(profile) when is_atom(profile) do
    Diagnostics.resolve_test_command_profile(profile)
  end

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


  defp attest_execution_profile_baseline(
         :test_relaxed,
         _llm_provider,
         _llm_cmd,
         _policy,
         _workdir,
         _open_pr,
         _merge_pr,
         _readiness_gate_approved,
         _test_command_profile,
         _actor_id,
         _repo,
         _github_repo,
         _startup_attestation_signing_key
       ),
       do: :ok

  defp attest_execution_profile_baseline(
         execution_profile,
         llm_provider,
         llm_cmd,
         policy,
         workdir,
         open_pr,
         merge_pr,
         readiness_gate_approved,
         test_command_profile,
         actor_id,
         repo,
         github_repo,
         startup_attestation_signing_key
       ) do
    observed = %{
      llm_provider: llm_provider,
      llm_cmd: normalize_command(llm_cmd),
      sandbox_mode: policy.sandbox_mode,
      command_allowlist: policy.command_allowlist,
      write_boundaries: policy.write_boundaries,
      open_pr: open_pr,
      merge_pr: merge_pr,
      readiness_gate_approved: readiness_gate_approved,
      test_command_profile: test_command_profile
    }

    baselines = approved_execution_profile_baselines(execution_profile, workdir)

    case Enum.find(baselines, fn baseline -> baseline_match?(baseline.policy, observed) end) do
      nil ->
        closest = closest_baseline(baselines, observed)
        drift_fields = drift_fields(closest.policy, observed)

        :ok =
          Audit.emit(:execution_profile_policy_drift_blocked, %{
            repo: github_repo || repo,
            actor_id: actor_id,
            execution_profile: execution_profile,
            baseline_id: closest.id,
            drift_fields: drift_fields,
            observed_policy: observed,
            expected_policy: closest.policy,
            attestation_signature:
              maybe_sign_execution_profile_attestation(nil, startup_attestation_signing_key),
            attestation_key_id: attestation_key_id(startup_attestation_signing_key)
          })

        {:error,
         "execution_profile #{execution_profile} drift detected from approved baseline: #{Enum.join(drift_fields, ", ")}"}

      baseline ->
        :ok =
          Audit.emit(:execution_profile_policy_attested, %{
            repo: github_repo || repo,
            actor_id: actor_id,
            execution_profile: execution_profile,
            baseline_id: baseline.id,
            drift_fields: [],
            observed_policy: observed,
            expected_policy: baseline.policy,
            attestation_signature:
              maybe_sign_execution_profile_attestation(observed, startup_attestation_signing_key),
            attestation_key_id: attestation_key_id(startup_attestation_signing_key)
          })

        :ok
    end
  end

  defp approved_execution_profile_baselines(:staging_restricted, workdir) do
    [
      %{
        id: "staging_restricted_default",
        policy: %{
          llm_provider: :codex,
          llm_cmd: LLM.default_cmd(:codex, nil, :staging_restricted),
          sandbox_mode: :workspace_write,
          command_allowlist: ["codex"],
          write_boundaries: expected_write_boundaries(workdir),
          open_pr: true,
          merge_pr: false,
          readiness_gate_approved: false,
          test_command_profile: :mix_test
        }
      }
    ]
  end

  defp approved_execution_profile_baselines(:production_hardened, workdir) do
    [
      %{
        id: "production_hardened_default",
        policy: %{
          llm_provider: :codex,
          llm_cmd: LLM.default_cmd(:codex, nil, :production_hardened),
          sandbox_mode: :read_only,
          command_allowlist: ["codex"],
          write_boundaries: expected_write_boundaries(workdir),
          open_pr: false,
          merge_pr: false,
          readiness_gate_approved: false,
          test_command_profile: :mix_test
        }
      },
      %{
        id: "production_hardened_readiness_approved_pr",
        policy: %{
          llm_provider: :codex,
          llm_cmd: LLM.default_cmd(:codex, nil, :production_hardened),
          sandbox_mode: :read_only,
          command_allowlist: ["codex"],
          write_boundaries: expected_write_boundaries(workdir),
          open_pr: true,
          merge_pr: false,
          readiness_gate_approved: true,
          test_command_profile: :mix_test
        }
      }
    ]
  end

  defp baseline_match?(expected, observed) do
    Enum.all?(Map.keys(expected), fn key ->
      Map.get(expected, key) == Map.get(observed, key)
    end)
  end

  defp closest_baseline(baselines, observed) do
    Enum.min_by(baselines, fn baseline ->
      baseline.policy
      |> drift_fields(observed)
      |> length()
    end)
  end

  defp drift_fields(expected, observed) do
    expected
    |> Map.keys()
    |> Enum.filter(fn key -> Map.get(expected, key) != Map.get(observed, key) end)
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  defp maybe_sign_execution_profile_attestation(_policy, signing_key)
       when not is_binary(signing_key),
       do: nil

  defp maybe_sign_execution_profile_attestation(policy, signing_key) do
    payload =
      policy
      |> case do
        nil -> %{}
        value -> value
      end
      |> Jason.encode!()

    :crypto.mac(:hmac, :sha256, signing_key, payload)
    |> Base.encode64()
  end

  defp attestation_key_id(signing_key) when is_binary(signing_key) and signing_key != "" do
    digest =
      signing_key
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:#{digest}"
  end

  defp attestation_key_id(_), do: "unsigned"

  defp normalize_command(value) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  defp normalize_command(value), do: value

  defp expected_write_boundaries(workdir) when is_binary(workdir), do: [workdir]
  defp expected_write_boundaries(_workdir), do: []

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

      not LLM.command_binary_allowed?(llm_cmd, ["codex"]) ->
        {:error, "staging_restricted requires codex command allowlist compliance"}

      String.contains?(llm_cmd || "", "--yolo") ->
        {:error, "staging_restricted forbids --yolo execution"}

      not LLM.codex_workspace_write_sandbox?(llm_cmd) ->
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

      not LLM.command_binary_allowed?(llm_cmd, ["codex"]) ->
        {:error, "production_hardened requires codex command allowlist compliance"}

      String.contains?(llm_cmd || "", "--yolo") ->
        {:error, "production_hardened forbids --yolo execution"}

      not LLM.codex_read_only_sandbox?(llm_cmd) ->
        {:error, "production_hardened requires codex sandbox mode read-only"}

      (open_pr or merge_pr) and not readiness_gate_approved ->
        {:error, "production_hardened requires readiness gate approval for sensitive operations"}

      true ->
        :ok
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

    case evaluate_configured_gate(runtime, :repo_allowlist, %{
           github_repo: github_repo,
           allowed_github_repos: allowed_github_repos
         }) do
      {:ok, %{status: :allow}} ->
        {:ok, github_repo}

      {:ok, %{status: :deny, reason: reason, details: %{reason_code: :repo_disallowed}}} ->
        :ok =
          Audit.emit(:github_repo_disallowed, %{
            repo: github_repo,
            actor_id: actor_id,
            allowed_repos: allowed_github_repos
          })

        {:error, reason}

      {:ok, %{status: :deny, reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end


  defp parse_incident_to_pr_canary_artifact_path(opts, runtime) do
    case Keyword.get(
           opts,
           :incident_to_pr_canary_artifact_path,
           runtime[:incident_to_pr_canary_artifact_path]
         ) do
      nil ->
        {:ok, nil}

      path when is_binary(path) ->
        trimmed = String.trim(path)

        if trimmed == "",
          do: {:error, "incident_to_pr_canary_artifact_path must not be empty"},
          else: {:ok, trimmed}

      _other ->
        {:error, "incident_to_pr_canary_artifact_path must be a string"}
    end
  end

  defp parse_incident_to_pr_canary_max_age_seconds(opts, runtime) do
    case parse_int(
           Keyword.get(
             opts,
             :incident_to_pr_canary_max_age_seconds,
             runtime[:incident_to_pr_canary_max_age_seconds]
           )
         ) do
      nil -> {:error, "incident_to_pr_canary_max_age_seconds must be a positive integer"}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "incident_to_pr_canary_max_age_seconds must be a positive integer"}
    end
  end


  defp validate_actor_identity(actor_id, github_token, allowed_actor_ids, runtime) do
    case evaluate_configured_gate(runtime, :actor_identity, %{
           actor_id: actor_id,
           allowed_actor_ids: allowed_actor_ids,
           github_token_present: token_present?(github_token)
         }) do
      {:ok, %{status: :allow}} -> :ok
      {:ok, %{status: :deny, reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_github_credential_permissions(
         github_token,
         scopes,
         github_live_permission_verification,
         startup_attestation_signing_key,
         open_pr,
         merge_pr,
         actor_id,
         github_repo,
         allowed_egress_hosts
       ) do
    if token_present?(github_token) and value_present?(github_repo) and (open_pr or merge_pr) do
      if github_live_permission_verification or token_present?(startup_attestation_signing_key) do
        verify_live_github_permissions(
          github_token,
          github_repo,
          actor_id,
          startup_attestation_signing_key,
          allowed_egress_hosts
        )
      else
        Compliance.validate_declared_github_credential_scopes(scopes, actor_id, github_repo)
      end
    else
      :ok
    end
  end

  defp verify_live_github_permissions(
         github_token,
         github_repo,
         actor_id,
         startup_attestation_signing_key,
         allowed_egress_hosts
       ) do
    if token_present?(startup_attestation_signing_key) do
      case GitHubCredentialEvidence.verify(
             github_token: github_token,
             github_repo: github_repo,
             actor_id: actor_id,
             required_scopes: Compliance.required_github_credential_scopes(),
             allowed_egress_hosts: allowed_egress_hosts,
             startup_attestation_signing_key: startup_attestation_signing_key
           ) do
        {:ok, _metadata} ->
          :ok

        {:error, {:missing_permissions, missing_scopes}} ->
        {:error,
           "github credential permissions must include live evidence for: #{Enum.join(missing_scopes, ", ")}"}

        {:error, _reason} ->
          {:error,
           "github credential live permission verification failed; startup blocked by fail-closed policy"}
      end
    else
      {:error,
       "startup_attestation_signing_key is required for live github permission verification"}
    end
  end


  defp validate_automated_pr_readiness(
         open_pr,
         github_token,
         github_repo,
         readiness_gate_approved,
         execution_profile,
         incident_to_pr_canary_artifact_path,
         incident_to_pr_canary_max_age_seconds,
         startup_attestation_signing_key,
         actor_id,
         github_base_branch,
         protected_branches,
         runtime
       ) do
    automated_pr_flow = automated_pr_flow?(open_pr, github_token, github_repo)

    case evaluate_configured_gate(runtime, :readiness, %{
           enforced: automated_pr_flow,
           open_pr: open_pr,
           readiness_gate_approved: readiness_gate_approved,
           execution_profile: execution_profile,
           github_base_branch: github_base_branch,
           protected_branches: protected_branches
         }) do
      {:ok, %{status: :deny, reason: reason, details: %{reason_code: reason_code}}} ->
        emit_readiness_blocked(github_repo, actor_id, github_base_branch, protected_branches,
          reason: reason_code
        )

        {:error, reason}

      {:ok, %{status: :deny, reason: reason}} ->
        {:error, reason}

      {:ok, %{status: :allow}} when automated_pr_flow ->
        case evaluate_configured_gate(runtime, :canary_release, %{
               enforced: automated_pr_flow,
               execution_profile: execution_profile,
               artifact_path: incident_to_pr_canary_artifact_path,
               max_age_seconds: incident_to_pr_canary_max_age_seconds,
               attestation_signing_key: startup_attestation_signing_key
             }) do
          {:ok, %{status: :allow, details: %{evidence: evidence}}} ->
            :ok =
              Audit.emit(:automated_pr_release_gate_passed, %{
                repo: github_repo,
                actor_id: actor_id,
                run_id: evidence.run_id,
                pr_number: evidence.pr_number,
                pr_url: evidence.pr_url,
                age_seconds: evidence.age_seconds,
                max_age_seconds: incident_to_pr_canary_max_age_seconds
              })

            :ok

          {:ok, %{status: :allow}} ->
            :ok

          {:ok, %{status: :deny, reason: reason, details: details}} ->
            :ok =
              Audit.emit(:automated_pr_readiness_blocked, %{
                repo: github_repo,
                actor_id: actor_id,
                base_branch: github_base_branch,
                protected_branches: protected_branches,
                reason:
                  Map.get(details, :reason_code, :incident_to_pr_canary_release_gate_failed),
                canary_reason: Map.get(details, :canary_reason)
              })

            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{status: :allow}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
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

end
