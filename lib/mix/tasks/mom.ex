defmodule Mix.Tasks.Mom do
  use Mix.Task

  alias Mom.Config

  @shortdoc "Monitor a BEAM node and open PRs for fixes"

  @moduledoc """
  Run Mom against a repo and a target BEAM node.

  Examples:
      mix mom /path/to/repo --node app@127.0.0.1 --cookie SECRET
  """

  @impl true
  def run(args) do
    with {:ok, config} <- parse_args(args),
         {:ok, _pid} <- Mom.start(config) do
      Process.sleep(:infinity)
    else
      {:error, reason} ->
        Mix.raise("mom failed: #{inspect(reason)}")
    end
  end

  @spec parse_args([String.t()]) :: {:ok, Config.t()} | {:error, String.t()}
  def parse_args(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: option_parser_spec())

    repo =
      case rest do
        [repo | _] -> repo
        _ -> nil
      end

    build_config(repo, opts)
  end

  defp build_config(repo, opts) do
    with :ok <- validate_secret_injection(opts) do
      opts =
        opts
        |> Keyword.put(:repo, repo)
        |> normalize_opts()

      Config.from_opts(opts)
    end
  end

  defp validate_secret_injection(opts) do
    cond do
      Keyword.has_key?(opts, :github_token) ->
        {:error, "github_token must be provided via MOM_GITHUB_TOKEN environment variable"}

      Keyword.has_key?(opts, :llm_api_key) ->
        {:error, "llm_api_key must be provided via MOM_LLM_API_KEY environment variable"}

      true ->
        :ok
    end
  end

  defp normalize_opts(opts) do
    mode =
      case Keyword.get(opts, :mode) do
        "inproc" -> :inproc
        "remote" -> :remote
        nil -> :remote
        other -> raise "invalid mode #{other}"
      end

    llm_provider =
      case Keyword.get(opts, :llm) do
        "claude_code" -> :claude_code
        "codex" -> :codex
        "api_anthropic" -> :api_anthropic
        "api_openai" -> :api_openai
        nil -> :claude_code
        other -> raise "invalid llm provider #{other}"
      end

    min_level =
      case Keyword.get(opts, :min_level) do
        "info" -> :info
        "warning" -> :warning
        "error" -> :error
        nil -> :error
        other -> raise "invalid min_level #{other}"
      end

    triage_mode =
      case Keyword.get(opts, :triage_mode) do
        "report" -> :report
        "fix" -> :fix
        nil -> :report
        other -> raise "invalid triage_mode #{other}"
      end

    opts
    |> Keyword.put(:mode, mode)
    |> Keyword.put(:llm_provider, llm_provider)
    |> Keyword.put(:min_level, min_level)
    |> Keyword.put(:triage_mode, triage_mode)
    |> maybe_parse_node()
    |> maybe_parse_cookie()
  end

  defp maybe_parse_node(opts) do
    case Keyword.get(opts, :node) do
      nil -> opts
      node_str -> Keyword.put(opts, :node, String.to_atom(node_str))
    end
  end

  defp maybe_parse_cookie(opts) do
    case Keyword.get(opts, :cookie) do
      nil -> opts
      cookie -> Keyword.put(opts, :cookie, String.to_atom(cookie))
    end
  end

  defp option_parser_spec do
    [
      node: :string,
      cookie: :string,
      mode: :string,
      llm: :string,
      llm_cmd: :string,
      execution_profile: :string,
      llm_api_key: :string,
      llm_api_url: :string,
      llm_model: :string,
      triage_on_diagnostics: :boolean,
      triage_mode: :string,
      diag_run_queue_mult: :integer,
      diag_mem_high_bytes: :integer,
      diag_cooldown_ms: :integer,
      git_ssh_command: :string,
      issue_rate_limit_per_hour: :integer,
      llm_rate_limit_per_hour: :integer,
      llm_spend_cap_cents_per_hour: :integer,
      llm_call_cost_cents: :integer,
      llm_token_cap_per_hour: :integer,
      llm_tokens_per_call_estimate: :integer,
      test_spend_cap_cents_per_hour: :integer,
      test_run_cost_cents: :integer,
      test_command_profile: :string,
      issue_dedupe_window_ms: :integer,
      redact_keys: :string,
      open_pr: :boolean,
      merge_pr: :boolean,
      readiness_gate_approved: :boolean,
      poll_interval_ms: :integer,
      max_concurrency: :integer,
      queue_max_size: :integer,
      tenant_queue_max_size: :integer,
      job_timeout_ms: :integer,
      overflow_policy: :string,
      durable_queue_path: :string,
      audit_retention_days: :integer,
      soc2_evidence_path: :string,
      pii_handling_policy: :string,
      observability_backend: :string,
      observability_export_path: :string,
      observability_export_interval_ms: :integer,
      slo_queue_depth_threshold: :integer,
      slo_drop_rate_threshold: :float,
      slo_failure_rate_threshold: :float,
      slo_latency_p95_ms_threshold: :integer,
      sla_triage_latency_p95_ms_target: :integer,
      sla_queue_durability_target: :float,
      sla_pr_turnaround_p95_ms_target: :integer,
      error_budget_triage_latency_overage_rate: :float,
      error_budget_queue_loss_rate: :float,
      error_budget_pr_turnaround_overage_rate: :float,
      allowed_github_repos: :string,
      allowed_actor_ids: :string,
      branch_name_prefix: :string,
      allowed_egress_hosts: :string,
      min_level: :string,
      dry_run: :boolean,
      github_token: :string,
      github_credential_scopes: :string,
      github_repo: :string,
      github_base_branch: :string,
      protected_branches: :string,
      actor_id: :string,
      workdir: :string
    ]
  end
end
