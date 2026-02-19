defmodule Mom.ConfigTest do
  use ExUnit.Case

  alias Mom.Config

  test "builds config from opts" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo", mode: :remote)
    assert config.repo == "/tmp/repo"
    assert config.mode == :remote
  end

  test "includes pipeline concurrency defaults" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert config.max_concurrency == 4
    assert config.queue_max_size == 200
    assert config.tenant_queue_max_size == nil
    assert config.job_timeout_ms == 120_000
    assert config.overflow_policy == :drop_newest
    assert config.durable_queue_path == nil
    assert "api.github.com" in config.allowed_egress_hosts
    assert config.observability_backend == :none
    assert config.observability_export_interval_ms == 5_000
    assert config.slo_queue_depth_threshold == 150
    assert config.slo_drop_rate_threshold == 0.05
    assert config.slo_failure_rate_threshold == 0.1
    assert config.slo_latency_p95_ms_threshold == 15_000
    assert config.sla_triage_latency_p95_ms_target == 15_000
    assert config.sla_queue_durability_target == 0.995
    assert config.sla_pr_turnaround_p95_ms_target == 900_000
    assert config.error_budget_triage_latency_overage_rate == 0.05
    assert config.error_budget_queue_loss_rate == 0.005
    assert config.error_budget_pr_turnaround_overage_rate == 0.1
    assert config.llm_spend_cap_cents_per_hour == nil
    assert config.llm_call_cost_cents == 0
    assert config.llm_token_cap_per_hour == nil
    assert config.llm_tokens_per_call_estimate == 0
    assert config.test_spend_cap_cents_per_hour == nil
    assert config.test_run_cost_cents == 0
    assert config.test_command_profile == :mix_test
    assert config.audit_retention_days == 30
    assert config.soc2_evidence_path == nil
    assert config.pii_handling_policy == :redact
  end

  test "parses redact keys from comma-separated string" do
    {:ok, config} =
      Config.from_opts(repo: "/tmp/repo", redact_keys: "foo, Bar , ,baz")

    assert config.redact_keys == ["foo", "Bar", "baz"]
  end

  test "defaults codex provider to yolo exec command profile" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo", llm_provider: :codex)
    assert config.llm_cmd == "codex --yolo exec"
  end

  test "preserves explicit codex command override" do
    {:ok, config} =
      Config.from_opts(repo: "/tmp/repo", llm_provider: :codex, llm_cmd: "codex exec")

    assert config.llm_cmd == "codex exec"
  end

  test "defines staging_restricted execution profile policy" do
    assert {:error, "staging_restricted requires an isolated --workdir write boundary"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :staging_restricted
             )

    workdir = isolated_workdir_fixture()

    assert {:error, "staging_restricted requires codex command allowlist compliance"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :staging_restricted,
               workdir: workdir,
               llm_cmd: "claude exec --sandbox workspace-write"
             )

    assert {:error, "staging_restricted requires codex sandbox mode workspace-write"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :staging_restricted,
               workdir: workdir,
               llm_cmd: "codex exec"
             )

    assert {:error, "staging_restricted forbids --yolo execution"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :staging_restricted,
               workdir: workdir,
               llm_cmd: "codex --yolo exec --sandbox workspace-write"
             )
  end

  test "accepts valid staging_restricted execution policy" do
    workdir = isolated_workdir_fixture()

    assert {:ok, config} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :staging_restricted,
               workdir: workdir,
               llm_cmd: "codex exec --sandbox workspace-write"
             )

    assert config.execution_profile == :staging_restricted
    assert config.sandbox_mode == :workspace_write
    assert config.command_allowlist == ["codex"]
    assert config.write_boundaries == [workdir]
  end

  test "defines production_hardened execution profile policy" do
    assert {:error, "production_hardened requires an isolated --workdir write boundary"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :production_hardened
             )

    workdir = isolated_workdir_fixture()

    assert {:error, "production_hardened requires codex command allowlist compliance"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :production_hardened,
               workdir: workdir,
               llm_cmd: "claude exec --sandbox read-only"
             )

    assert {:error, "production_hardened requires codex sandbox mode read-only"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :production_hardened,
               workdir: workdir,
               llm_cmd: "codex exec"
             )

    assert {:error, "production_hardened forbids --yolo execution"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :production_hardened,
               workdir: workdir,
               llm_cmd: "codex --yolo exec --sandbox read-only"
             )

    assert {:error,
            "production_hardened requires readiness gate approval for sensitive operations"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :production_hardened,
               workdir: workdir,
               open_pr: true,
               readiness_gate_approved: false
             )
  end

  test "accepts valid production_hardened execution policy" do
    workdir = isolated_workdir_fixture()

    assert {:ok, config} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :production_hardened,
               workdir: workdir
             )

    assert config.execution_profile == :production_hardened
    assert config.llm_cmd == "codex exec --sandbox read-only"
    assert config.sandbox_mode == :read_only
    assert config.command_allowlist == ["codex"]
    assert config.write_boundaries == [workdir]
    assert config.open_pr == false

    assert {:ok, approved} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :production_hardened,
               workdir: workdir,
               open_pr: true,
               readiness_gate_approved: true
             )

    assert approved.open_pr
  end

  test "fails closed when staging_restricted runtime policy drifts to yolo command" do
    workdir = isolated_workdir_fixture()

    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_provider: :codex,
        execution_profile: :staging_restricted,
        workdir: workdir,
        llm_cmd: "codex exec --sandbox workspace-write"
      )

    drifted = %{config | llm_cmd: "codex --yolo exec --sandbox workspace-write"}

    assert {:error, "staging_restricted forbids --yolo execution"} =
             Config.validate_runtime_policy(drifted)
  end

  test "fails closed when production_hardened runtime policy drifts from protected baseline" do
    workdir = isolated_workdir_fixture()

    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_provider: :codex,
        execution_profile: :production_hardened,
        workdir: workdir
      )

    drifted = %{config | sandbox_mode: :workspace_write}

    assert {:error, "production_hardened requires codex sandbox mode read-only"} =
             Config.validate_runtime_policy(drifted)
  end

  test "uses runtime env defaults" do
    Application.put_env(:mom, :llm_cmd, "cat")
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert config.llm_cmd == "cat"
  after
    Application.delete_env(:mom, :llm_cmd)
  end

  test "loads secrets from environment variables when runtime config is unset" do
    System.put_env("MOM_GITHUB_TOKEN", "env-github-token")
    System.put_env("MOM_LLM_API_KEY", "env-llm-key")

    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        actor_id: "mom-app[bot]",
        allowed_actor_ids: ["mom-app[bot]"]
      )

    assert config.github_token == "env-github-token"
    assert config.llm_api_key == "env-llm-key"
  after
    System.delete_env("MOM_GITHUB_TOKEN")
    System.delete_env("MOM_LLM_API_KEY")
  end

  test "fails closed when node version does not meet minimum major requirement" do
    original = System.get_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE")

    try do
      System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", "v16.20.2")

      assert {:error, "node --version must be >= 18.x; found v16.20.2"} =
               Config.from_opts(repo: "/tmp/repo")
    after
      if is_nil(original),
        do: System.delete_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE"),
        else: System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", original)
    end
  end

  test "fails closed when otp version does not match pinned patch version" do
    original_node = System.get_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE")
    original_otp = System.get_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE")

    try do
      System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", "v24.6.0")
      System.put_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", "28.0.1")

      assert {:error, "erlang/otp version must be 28.0.2; found 28.0.1"} =
               Config.from_opts(repo: "/tmp/repo")
    after
      if is_nil(original_node),
        do: System.delete_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE"),
        else: System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", original_node)

      if is_nil(original_otp),
        do: System.delete_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE"),
        else: System.put_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", original_otp)
    end
  end

  test "default redact keys include password" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert "password" in config.redact_keys
  end

  test "parses numeric env values" do
    Application.put_env(:mom, :issue_rate_limit_per_hour, "12")
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert config.issue_rate_limit_per_hour == 12
  after
    Application.delete_env(:mom, :issue_rate_limit_per_hour)
  end

  test "startup prunes stale acceptance build artifacts from cwd" do
    root =
      Path.join(
        System.tmp_dir!(),
        "mom-config-build-artifact-prune-#{System.unique_integer([:positive])}"
      )

    stale_runner = Path.join(root, "_build_runner_burst_stale")
    stale_worker = Path.join(root, "_build_acceptance_worker_stale_0")
    fresh_worker = Path.join(root, "_build_acceptance_worker_fresh_0")
    keep_other = Path.join(root, "_build_kept_other")

    on_exit(fn ->
      Application.delete_env(:mom, :acceptance_build_artifact_retention_seconds)
      Application.delete_env(:mom, :acceptance_build_artifact_keep_latest)
      File.rm_rf!(root)
    end)

    File.rm_rf!(root)
    File.mkdir_p!(stale_runner)
    File.mkdir_p!(stale_worker)
    File.mkdir_p!(fresh_worker)
    File.mkdir_p!(keep_other)

    now = System.os_time(:second)
    set_directory_mtime!(stale_runner, now - 3_600)
    set_directory_mtime!(stale_worker, now - 3_600)
    set_directory_mtime!(fresh_worker, now)

    Application.put_env(:mom, :acceptance_build_artifact_retention_seconds, 300)
    Application.put_env(:mom, :acceptance_build_artifact_keep_latest, 1)

    File.cd!(root, fn ->
      assert {:ok, _config} =
               Config.from_opts(
                 repo: "/tmp/repo",
                 mode: :inproc,
                 toolchain_node_version_override: "v24.6.0",
                 toolchain_otp_version_override: "28.0.2"
               )
    end)

    refute File.exists?(stale_runner)
    refute File.exists?(stale_worker)
    assert File.dir?(fresh_worker)
    assert File.dir?(keep_other)
  end

  test "parses pipeline concurrency values from opts" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        max_concurrency: 8,
        queue_max_size: 350,
        tenant_queue_max_size: 120,
        job_timeout_ms: 9_000,
        overflow_policy: :drop_oldest,
        durable_queue_path: "/tmp/mom/queue.bin",
        audit_retention_days: 45,
        soc2_evidence_path: "/tmp/mom/evidence.jsonl",
        pii_handling_policy: :drop
      )

    assert config.max_concurrency == 8
    assert config.queue_max_size == 350
    assert config.tenant_queue_max_size == 120
    assert config.job_timeout_ms == 9_000
    assert config.overflow_policy == :drop_oldest
    assert config.durable_queue_path == "/tmp/mom/queue.bin"
    assert config.audit_retention_days == 45
    assert config.soc2_evidence_path == "/tmp/mom/evidence.jsonl"
    assert config.pii_handling_policy == :drop
  end

  test "parses spend control values from opts" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_spend_cap_cents_per_hour: 500,
        llm_call_cost_cents: 25,
        llm_token_cap_per_hour: 20_000,
        llm_tokens_per_call_estimate: 1_500,
        test_spend_cap_cents_per_hour: 750,
        test_run_cost_cents: 30,
        test_command_profile: :mix_test_no_start
      )

    assert config.llm_spend_cap_cents_per_hour == 500
    assert config.llm_call_cost_cents == 25
    assert config.llm_token_cap_per_hour == 20_000
    assert config.llm_tokens_per_call_estimate == 1_500
    assert config.test_spend_cap_cents_per_hour == 750
    assert config.test_run_cost_cents == 30
    assert config.test_command_profile == :mix_test_no_start
  end

  test "validates pipeline concurrency values" do
    assert {:error, "max_concurrency must be a non-negative integer"} =
             Config.from_opts(repo: "/tmp/repo", max_concurrency: -1)

    assert {:error, "queue_max_size must be a positive integer"} =
             Config.from_opts(repo: "/tmp/repo", queue_max_size: 0)

    assert {:error, "tenant_queue_max_size must be nil or a positive integer"} =
             Config.from_opts(repo: "/tmp/repo", tenant_queue_max_size: 0)

    assert {:error, "job_timeout_ms must be a positive integer"} =
             Config.from_opts(repo: "/tmp/repo", job_timeout_ms: 0)

    assert {:error, "overflow_policy must be :drop_newest or :drop_oldest"} =
             Config.from_opts(repo: "/tmp/repo", overflow_policy: :drop_middle)

    assert {:error, "durable_queue_path must be nil or a non-empty string"} =
             Config.from_opts(repo: "/tmp/repo", durable_queue_path: "")

    assert {:error, "audit_retention_days must be a positive integer"} =
             Config.from_opts(repo: "/tmp/repo", audit_retention_days: 0)

    assert {:error, "soc2_evidence_path must be nil or a non-empty string"} =
             Config.from_opts(repo: "/tmp/repo", soc2_evidence_path: "")

    assert {:error, "pii_handling_policy must be :redact or :drop"} =
             Config.from_opts(repo: "/tmp/repo", pii_handling_policy: :mask)
  end

  test "validates spend control values" do
    assert {:error, "llm_spend_cap_cents_per_hour must be nil or a positive integer"} =
             Config.from_opts(repo: "/tmp/repo", llm_spend_cap_cents_per_hour: 0)

    assert {:error, "llm_call_cost_cents must be a non-negative integer"} =
             Config.from_opts(repo: "/tmp/repo", llm_call_cost_cents: -1)

    assert {:error, "llm_token_cap_per_hour must be nil or a positive integer"} =
             Config.from_opts(repo: "/tmp/repo", llm_token_cap_per_hour: 0)

    assert {:error, "llm_tokens_per_call_estimate must be a non-negative integer"} =
             Config.from_opts(repo: "/tmp/repo", llm_tokens_per_call_estimate: -1)

    assert {:error, "test_spend_cap_cents_per_hour must be nil or a positive integer"} =
             Config.from_opts(repo: "/tmp/repo", test_spend_cap_cents_per_hour: 0)

    assert {:error, "test_run_cost_cents must be a non-negative integer"} =
             Config.from_opts(repo: "/tmp/repo", test_run_cost_cents: -1)

    assert {:error, "test_command_profile must be one of: mix_test, mix_test_no_start"} =
             Config.from_opts(repo: "/tmp/repo", test_command_profile: :unknown)

    workdir = isolated_workdir_fixture()

    assert {:error,
            "test_command_profile mix_test_no_start is not allowed for execution_profile production_hardened"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :codex,
               execution_profile: :production_hardened,
               workdir: workdir,
               test_command_profile: :mix_test_no_start
             )
  end

  test "parses observability backend and slo thresholds" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        observability_backend: :prometheus,
        observability_export_path: "/tmp/mom.prom",
        observability_export_interval_ms: 2_000,
        slo_queue_depth_threshold: 200,
        slo_drop_rate_threshold: 0.1,
        slo_failure_rate_threshold: 0.15,
        slo_latency_p95_ms_threshold: 25_000,
        sla_triage_latency_p95_ms_target: 12_000,
        sla_queue_durability_target: 0.999,
        sla_pr_turnaround_p95_ms_target: 600_000,
        error_budget_triage_latency_overage_rate: 0.02,
        error_budget_queue_loss_rate: 0.001,
        error_budget_pr_turnaround_overage_rate: 0.05
      )

    assert config.observability_backend == :prometheus
    assert config.observability_export_path == "/tmp/mom.prom"
    assert config.observability_export_interval_ms == 2_000
    assert config.slo_queue_depth_threshold == 200
    assert config.slo_drop_rate_threshold == 0.1
    assert config.slo_failure_rate_threshold == 0.15
    assert config.slo_latency_p95_ms_threshold == 25_000
    assert config.sla_triage_latency_p95_ms_target == 12_000
    assert config.sla_queue_durability_target == 0.999
    assert config.sla_pr_turnaround_p95_ms_target == 600_000
    assert config.error_budget_triage_latency_overage_rate == 0.02
    assert config.error_budget_queue_loss_rate == 0.001
    assert config.error_budget_pr_turnaround_overage_rate == 0.05
  end

  test "validates observability settings" do
    assert {:error, "observability_backend must be :none or :prometheus"} =
             Config.from_opts(repo: "/tmp/repo", observability_backend: :datadog)

    assert {:error,
            "observability_export_path is required when observability_backend is :prometheus"} =
             Config.from_opts(repo: "/tmp/repo", observability_backend: :prometheus)

    assert {:error, "observability_export_interval_ms must be a positive integer"} =
             Config.from_opts(
               repo: "/tmp/repo",
               observability_export_interval_ms: 0
             )

    assert {:error, "slo_drop_rate_threshold must be between 0.0 and 1.0"} =
             Config.from_opts(repo: "/tmp/repo", slo_drop_rate_threshold: 1.5)

    assert {:error, "sla_queue_durability_target must be between 0.0 and 1.0"} =
             Config.from_opts(repo: "/tmp/repo", sla_queue_durability_target: 1.5)

    assert {:error, "error_budget_queue_loss_rate must be between 0.0 and 1.0"} =
             Config.from_opts(repo: "/tmp/repo", error_budget_queue_loss_rate: -0.1)
  end

  test "enforces github repo allowlist when configured" do
    assert {:ok, config} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_repo: "acme/mom",
               allowed_github_repos: ["acme/mom", "acme/other"]
             )

    assert config.allowed_github_repos == ["acme/mom", "acme/other"]
  end

  test "rejects github repo not in allowlist" do
    assert {:error, "github_repo must be set when allowed_github_repos is configured"} =
             Config.from_opts(
               repo: "/tmp/repo",
               allowed_github_repos: ["acme/mom"]
             )

    assert {:error, "github_repo is not allowed"} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_repo: "evil/repo",
               allowed_github_repos: ["acme/mom"]
             )
  end

  test "emits audit event for disallowed github repo target" do
    handler_id = "mom-config-disallowed-repo-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:mom, :audit, :github_repo_disallowed],
        fn event, _measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, "github_repo is not allowed"} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_repo: "evil/repo",
               allowed_github_repos: ["acme/mom"]
             )

    assert_receive {:telemetry_event, [:mom, :audit, :github_repo_disallowed], metadata}
    assert metadata.repo == "evil/repo"
    assert metadata.allowed_repos == ["acme/mom"]
  end

  test "validates required egress hosts and llm api url host" do
    assert {:ok, config} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :api_openai,
               allowed_egress_hosts: "api.github.com,api.openai.com"
             )

    assert config.allowed_egress_hosts == ["api.github.com", "api.openai.com"]

    assert {:error, "allowed_egress_hosts is missing required host api.openai.com"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :api_openai,
               allowed_egress_hosts: "api.github.com,api.anthropic.com"
             )

    assert {:error, "llm_api_url must be a valid URL with a host"} =
             Config.from_opts(
               repo: "/tmp/repo",
               llm_provider: :api_openai,
               llm_api_url: "not-a-url"
             )
  end

  test "includes branch naming prefix default" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert config.branch_name_prefix == "mom"
  end

  test "accepts custom branch naming prefix" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo", branch_name_prefix: "mom/incidents")
    assert config.branch_name_prefix == "mom/incidents"
  end

  test "rejects invalid branch naming prefix" do
    assert {:error, "branch_name_prefix is not a valid git branch prefix"} =
             Config.from_opts(repo: "/tmp/repo", branch_name_prefix: "bad prefix")
  end

  test "includes default actor id" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert config.actor_id == "mom"
  end

  test "accepts custom actor id" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo", actor_id: "machine-user")
    assert config.actor_id == "machine-user"
  end

  test "requires actor allowlist when github token is configured" do
    assert {:error, "allowed_actor_ids must be set when github_token is configured"} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_token: "token",
               actor_id: "machine-user"
             )
  end

  test "enforces actor allowlist when configured" do
    assert {:ok, config} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_token: "token",
               actor_id: "mom-bot",
               allowed_actor_ids: ["mom-bot", "mom-staging"]
             )

    assert config.actor_id == "mom-bot"
    assert config.allowed_actor_ids == ["mom-bot", "mom-staging"]

    assert {:error, "actor_id is not allowed"} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_token: "token",
               actor_id: "personal-user",
               allowed_actor_ids: ["mom-bot", "mom-staging"]
             )
  end

  test "requires dedicated machine actor identity for github credentials" do
    assert {:error, "actor_id must be a dedicated machine identity"} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_token: "token",
               actor_id: "jef",
               allowed_actor_ids: ["jef"]
             )

    assert {:ok, config} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_token: "token",
               actor_id: "mom-app[bot]",
               allowed_actor_ids: ["mom-app[bot]"]
             )

    assert config.actor_id == "mom-app[bot]"
  end

  test "requires explicit readiness gate approval before automated PR creation" do
    assert {:error, "readiness_gate_approved must be true before enabling automated PR creation"} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_repo: "acme/mom",
               github_token: "token",
               actor_id: "mom-app[bot]",
               allowed_actor_ids: ["mom-app[bot]"]
             )

    assert {:ok, config} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_repo: "acme/mom",
               github_token: "token",
               actor_id: "mom-app[bot]",
               allowed_actor_ids: ["mom-app[bot]"],
               readiness_gate_approved: true
             )

    assert config.readiness_gate_approved
  end

  test "emits audit event when automated PR readiness gate blocks startup" do
    handler_id = "mom-config-readiness-blocked-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:mom, :audit, :automated_pr_readiness_blocked],
        fn event, _measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, "readiness_gate_approved must be true before enabling automated PR creation"} =
             Config.from_opts(
               repo: "/tmp/repo",
               github_repo: "acme/mom",
               github_token: "token",
               actor_id: "mom-app[bot]",
               allowed_actor_ids: ["mom-app[bot]"]
             )

    assert_receive {:telemetry_event, [:mom, :audit, :automated_pr_readiness_blocked], metadata}
    assert metadata.repo == "acme/mom"
    assert metadata.actor_id == "mom-app[bot]"
    assert metadata.reason == :readiness_gate_not_approved
  end

  test "defaults to protected main branch with PR-only enforcement target" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert config.github_base_branch == "main"
    assert config.protected_branches == ["main"]
  end

  test "parses protected branch and base branch options" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        github_base_branch: "release",
        protected_branches: "main,release"
      )

    assert config.github_base_branch == "release"
    assert config.protected_branches == ["main", "release"]
  end

  test "rejects workdir that is not an isolated git worktree" do
    repo = Mom.TestHelper.create_repo()

    assert {:error, "workdir must reference an isolated git worktree"} =
             Config.from_opts(repo: repo, workdir: repo)
  end

  test "accepts explicit workdir when it is an isolated git worktree" do
    repo = Mom.TestHelper.create_repo()

    workdir =
      Path.join(System.tmp_dir!(), "mom-config-worktree-#{System.unique_integer([:positive])}")

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    assert :ok = Mom.Git.add_worktree(repo, workdir)

    assert {:ok, config} =
             Config.from_opts(repo: repo, workdir: workdir)

    assert config.workdir == workdir
  end

  defp isolated_workdir_fixture do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "mom-config-policy-worktree-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, ".git"), "gitdir: /tmp/mom-config-policy-gitdir\n")
    workdir
  end

  defp set_directory_mtime!(path, unix_seconds) do
    datetime = :calendar.system_time_to_local_time(unix_seconds, :second)
    :ok = :file.change_time(String.to_charlist(path), datetime)
  end
end
