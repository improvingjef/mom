defmodule Mom.Config do
  @moduledoc false

  alias Mom.{AcceptanceLifecycle, Audit}

  require Logger

  @minimum_node_major 18
  @required_otp_version "28.0.2"
  @required_elixir_series "1.19"
  @required_github_credential_scopes ["contents", "pull_requests", "issues"]
  @default_acceptance_build_artifact_retention_seconds 86_400
  @default_acceptance_build_artifact_keep_latest 8

  @test_command_profiles %{
    mix_test: %{
      command: "mix",
      args: ["test"],
      allowed_execution_profiles: [:test_relaxed, :staging_restricted, :production_hardened]
    },
    mix_test_no_start: %{
      command: "mix",
      args: ["test", "--no-start"],
      allowed_execution_profiles: [:test_relaxed]
    }
  }

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
    :test_command_profile,
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
    :audit_retention_days,
    :soc2_evidence_path,
    :pii_handling_policy,
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
    :github_credential_scopes,
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
          test_command_profile: :mix_test | :mix_test_no_start,
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
          audit_retention_days: pos_integer(),
          soc2_evidence_path: String.t() | nil,
          pii_handling_policy: :redact | :drop,
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
          github_credential_scopes: [String.t()],
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

        with :ok <- validate_toolchain_prerequisites(opts, runtime),
             {:ok, acceptance_build_artifact_retention_seconds} <-
               parse_non_neg_int(
                 opts,
                 runtime,
                 :acceptance_build_artifact_retention_seconds,
                 @default_acceptance_build_artifact_retention_seconds
               ),
             {:ok, acceptance_build_artifact_keep_latest} <-
               parse_non_neg_int(
                 opts,
                 runtime,
                 :acceptance_build_artifact_keep_latest,
                 @default_acceptance_build_artifact_keep_latest
               ),
             :ok <-
               maybe_prune_ephemeral_acceptance_build_artifacts(
                 acceptance_build_artifact_retention_seconds,
                 acceptance_build_artifact_keep_latest
               ),
             {:ok, max_concurrency} <- parse_non_neg_int(opts, runtime, :max_concurrency, 4),
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
             {:ok, audit_retention_days} <-
               parse_pos_int(opts, runtime, :audit_retention_days, 30),
             {:ok, soc2_evidence_path} <- parse_soc2_evidence_path(opts, runtime),
             {:ok, pii_handling_policy} <- parse_pii_handling_policy(opts, runtime),
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
             {:ok, github_credential_scopes} <- parse_github_credential_scopes(opts, runtime),
             :ok <-
               validate_required_egress_hosts(llm_provider, llm_api_url, allowed_egress_hosts),
             {:ok, github_base_branch} <- parse_github_base_branch(opts, runtime),
             {:ok, protected_branches} <-
               parse_protected_branches(opts, runtime, github_base_branch),
             {:ok, readiness_gate_approved} <- parse_readiness_gate_approved(opts, runtime),
             {:ok, merge_pr} <- parse_merge_pr(opts, runtime),
             {:ok, workdir} <- parse_workdir(opts, runtime),
             {:ok, execution_profile} <- parse_execution_profile(opts, runtime),
             {:ok, test_command_profile} <- parse_test_command_profile(opts, runtime),
             {:ok, open_pr} <- parse_open_pr(opts, runtime, execution_profile: execution_profile),
             llm_cmd <- default_llm_cmd(llm_provider, llm_cmd_override, execution_profile),
             policy <- execution_policy(execution_profile, workdir),
             :ok <- validate_test_command_profile_policy(test_command_profile, execution_profile),
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
               validate_github_credential_scopes(
                 github_token,
                 github_credential_scopes,
                 open_pr,
                 merge_pr,
                 actor_id,
                 Keyword.get(opts, :github_repo) || runtime[:github_repo]
               ),
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
             test_command_profile: test_command_profile,
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
             audit_retention_days: audit_retention_days,
             soc2_evidence_path: soc2_evidence_path,
             pii_handling_policy: pii_handling_policy,
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
             github_credential_scopes: github_credential_scopes,
             github_repo: github_repo,
             github_base_branch: github_base_branch,
             protected_branches: protected_branches,
             actor_id: actor_id,
             workdir: workdir
           }}
        end
    end
  end

  defp validate_toolchain_prerequisites(opts, runtime) do
    with {:ok, node_version} <- detect_node_version(opts, runtime),
         :ok <- validate_node_version(node_version, required_node_major(runtime)),
         {:ok, otp_version} <- detect_otp_version(opts, runtime),
         :ok <- validate_otp_version(otp_version, required_otp_version(runtime)),
         {:ok, elixir_version} <- detect_elixir_version(opts, runtime),
         :ok <- validate_elixir_version(elixir_version, required_elixir_series(runtime)) do
      :ok
    end
  end

  defp required_node_major(runtime) do
    case parse_int(runtime[:required_node_major]) do
      value when is_integer(value) and value > 0 -> value
      _ -> @minimum_node_major
    end
  end

  defp required_otp_version(runtime) do
    case runtime[:required_otp_version] do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> @required_otp_version
    end
  end

  defp required_elixir_series(runtime) do
    case runtime[:required_elixir_series] do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> @required_elixir_series
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

  defp validate_elixir_version(actual_version, required_series) do
    with {:ok, required_major, required_minor} <- parse_elixir_series(required_series),
         {:ok, parsed} <- Version.parse(actual_version),
         true <- parsed.pre == [] do
      if parsed.major == required_major and parsed.minor == required_minor do
        :ok
      else
        {:error, "elixir version must be stable #{required_series}.x; found #{actual_version}"}
      end
    else
      _ ->
        {:error, "elixir version must be stable #{required_series}.x; found #{actual_version}"}
    end
  end

  defp parse_elixir_series(series) do
    case Regex.run(~r/^(\d+)\.(\d+)$/, series) do
      [_full, major, minor] ->
        {major_int, ""} = Integer.parse(major)
        {minor_int, ""} = Integer.parse(minor)
        {:ok, major_int, minor_int}

      _ ->
        {:error, :invalid_required_elixir_series}
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

  defp maybe_prune_ephemeral_acceptance_build_artifacts(retention_seconds, keep_latest)
       when is_integer(retention_seconds) and retention_seconds >= 0 and is_integer(keep_latest) and
              keep_latest >= 0 do
    case File.cwd() do
      {:ok, cwd} ->
        case AcceptanceLifecycle.prune_ephemeral_build_artifacts(cwd,
               retention_seconds: retention_seconds,
               keep_latest: keep_latest
             ) do
          {:ok, _summary} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "mom: failed pruning ephemeral acceptance build artifacts in #{cwd}: #{inspect(reason)}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning(
          "mom: failed resolving cwd for acceptance build artifact pruning: #{inspect(reason)}"
        )

        :ok
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
           ),
         :ok <-
           validate_test_command_profile_policy(
             config.test_command_profile,
             config.execution_profile
           ) do
      :ok
    end
  end

  @spec resolve_test_command_profile(atom()) ::
          {:ok, %{command: String.t(), args: [String.t()], allowed_execution_profiles: [atom()]}}
          | {:error, String.t()}
  def resolve_test_command_profile(profile) when is_atom(profile) do
    case Map.get(@test_command_profiles, profile) do
      nil -> {:error, "unknown test command profile #{profile}"}
      spec -> {:ok, spec}
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

  defp parse_github_credential_scopes(opts, runtime) do
    value =
      Keyword.get(opts, :github_credential_scopes) ||
        runtime[:github_credential_scopes] ||
        System.get_env("MOM_GITHUB_CREDENTIAL_SCOPES")

    scopes =
      value
      |> normalize_allowed_repos()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    {:ok, scopes}
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

  defp parse_test_command_profile(opts, runtime) do
    profile =
      Keyword.get(opts, :test_command_profile, runtime[:test_command_profile] || :mix_test)

    with {:ok, normalized} <- normalize_test_command_profile(profile),
         {:ok, _spec} <- resolve_test_command_profile(normalized) do
      {:ok, normalized}
    else
      {:error, _reason} ->
        {:error, "test_command_profile must be one of: mix_test, mix_test_no_start"}
    end
  end

  defp normalize_test_command_profile(profile) when is_atom(profile) do
    {:ok, profile}
  end

  defp normalize_test_command_profile(profile) when is_binary(profile) do
    case profile do
      "mix_test" -> {:ok, :mix_test}
      "mix_test_no_start" -> {:ok, :mix_test_no_start}
      _other -> {:error, :invalid_test_command_profile}
    end
  end

  defp normalize_test_command_profile(_profile), do: {:error, :invalid_test_command_profile}

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

  defp validate_test_command_profile_policy(test_command_profile, execution_profile) do
    with {:ok, spec} <- resolve_test_command_profile(test_command_profile) do
      if execution_profile in spec.allowed_execution_profiles do
        :ok
      else
        {:error,
         "test_command_profile #{test_command_profile} is not allowed for execution_profile #{execution_profile}"}
      end
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

  defp parse_soc2_evidence_path(opts, runtime) do
    case Keyword.get(opts, :soc2_evidence_path, runtime[:soc2_evidence_path]) do
      nil ->
        {:ok, nil}

      path when is_binary(path) ->
        trimmed = String.trim(path)

        if trimmed == "",
          do: {:error, "soc2_evidence_path must be nil or a non-empty string"},
          else: {:ok, trimmed}

      _other ->
        {:error, "soc2_evidence_path must be nil or a non-empty string"}
    end
  end

  defp parse_pii_handling_policy(opts, runtime) do
    case Keyword.get(opts, :pii_handling_policy, runtime[:pii_handling_policy]) do
      nil -> {:ok, :redact}
      :redact -> {:ok, :redact}
      :drop -> {:ok, :drop}
      "redact" -> {:ok, :redact}
      "drop" -> {:ok, :drop}
      _other -> {:error, "pii_handling_policy must be :redact or :drop"}
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

  defp validate_github_credential_scopes(
         github_token,
         scopes,
         open_pr,
         merge_pr,
         actor_id,
         github_repo
       ) do
    if token_present?(github_token) and (open_pr or merge_pr) do
      missing_scopes = @required_github_credential_scopes -- scopes

      if missing_scopes == [] do
        :ok
      else
        :ok =
          Audit.emit(:github_credential_scope_blocked, %{
            repo: github_repo,
            actor_id: actor_id,
            required_scopes: @required_github_credential_scopes,
            provided_scopes: scopes,
            missing_scopes: missing_scopes
          })

        {:error, "github credential scopes must include: contents, pull_requests, issues"}
      end
    else
      :ok
    end
  end

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
