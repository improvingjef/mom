defmodule Mix.Tasks.MomTaskTest do
  use ExUnit.Case, async: true

  test "parse_args accepts pipeline concurrency flags" do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--mode",
        "inproc",
        "--max-concurrency",
        "6",
        "--queue-max-size",
        "333",
        "--tenant-queue-max-size",
        "111",
        "--job-timeout-ms",
        "45000",
        "--overflow-policy",
        "drop_oldest",
        "--durable-queue-path",
        "/tmp/mom/queue.bin"
      ])

    assert config.mode == :inproc
    assert config.max_concurrency == 6
    assert config.queue_max_size == 333
    assert config.tenant_queue_max_size == 111
    assert config.job_timeout_ms == 45_000
    assert config.overflow_policy == :drop_oldest
    assert config.durable_queue_path == "/tmp/mom/queue.bin"
  end

  test "parse_args accepts spend control flags" do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm-spend-cap-cents-per-hour",
        "500",
        "--llm-call-cost-cents",
        "25",
        "--llm-token-cap-per-hour",
        "20000",
        "--llm-tokens-per-call-estimate",
        "1500",
        "--test-spend-cap-cents-per-hour",
        "750",
        "--test-run-cost-cents",
        "30",
        "--test-command-profile",
        "mix_test_no_start"
      ])

    assert config.llm_spend_cap_cents_per_hour == 500
    assert config.llm_call_cost_cents == 25
    assert config.llm_token_cap_per_hour == 20_000
    assert config.llm_tokens_per_call_estimate == 1_500
    assert config.test_spend_cap_cents_per_hour == 750
    assert config.test_run_cost_cents == 30
    assert config.test_command_profile == :mix_test_no_start
  end

  test "parse_args rejects invalid test command profiles" do
    assert {:error, "test_command_profile must be one of: mix_test, mix_test_no_start"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--test-command-profile",
               "not_a_profile"
             ])
  end

  test "parse_args rejects invalid overflow policy values" do
    assert {:error, "overflow_policy must be :drop_newest or :drop_oldest"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--overflow-policy",
               "invalid"
             ])
  end

  test "parse_args defaults codex profile to yolo exec command" do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex"
      ])

    assert config.llm_provider == :codex
    assert config.llm_cmd == "codex --yolo exec"
    assert config.execution_profile == :test_relaxed
  end

  test "parse_args accepts staging_restricted execution profile" do
    workdir = isolated_workdir_fixture()

    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex",
        "--execution-profile",
        "staging_restricted",
        "--workdir",
        workdir
      ])

    assert config.execution_profile == :staging_restricted
    assert config.llm_cmd == "codex exec --sandbox workspace-write"
  end

  test "parse_args accepts production_hardened execution profile" do
    workdir = isolated_workdir_fixture()

    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex",
        "--execution-profile",
        "production_hardened",
        "--workdir",
        workdir
      ])

    assert config.execution_profile == :production_hardened
    assert config.llm_cmd == "codex exec --sandbox read-only"
    assert config.sandbox_mode == :read_only
    assert config.open_pr == false

    assert {:error,
            "production_hardened requires readiness gate approval for sensitive operations"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--llm",
               "codex",
               "--execution-profile",
               "production_hardened",
               "--workdir",
               workdir,
               "--open-pr"
             ])
  end

  test "parse_args accepts github repo allowlist flag" do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "acme/mom",
        "--allowed-github-repos",
        "acme/mom,acme/other"
      ])

    assert config.github_repo == "acme/mom"
    assert config.allowed_github_repos == ["acme/mom", "acme/other"]
  end

  test "parse_args accepts branch naming prefix flag" do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--branch-name-prefix",
        "mom/incidents"
      ])

    assert config.branch_name_prefix == "mom/incidents"
  end

  test "parse_args accepts actor id flag" do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--actor-id",
        "machine-user"
      ])

    assert config.actor_id == "machine-user"
  end

  test "parse_args enforces actor allowlist for github credentials" do
    System.put_env("MOM_GITHUB_TOKEN", "token")

    assert {:error, "allowed_actor_ids must be set when github_token is configured"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--actor-id",
               "mom-bot"
             ])

    assert {:ok, config} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--actor-id",
               "mom-bot",
               "--allowed-actor-ids",
               "mom-bot,mom-staging"
             ])

    assert config.allowed_actor_ids == ["mom-bot", "mom-staging"]
  after
    System.delete_env("MOM_GITHUB_TOKEN")
  end

  test "parse_args rejects non-machine actor identities for github credentials" do
    System.put_env("MOM_GITHUB_TOKEN", "token")

    assert {:error, "actor_id must be a dedicated machine identity"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--actor-id",
               "jef",
               "--allowed-actor-ids",
               "jef"
             ])
  after
    System.delete_env("MOM_GITHUB_TOKEN")
  end

  test "parse_args rejects github token provided via CLI flag" do
    assert {:error, "github_token must be provided via MOM_GITHUB_TOKEN environment variable"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--github-token",
               "token-from-flag"
             ])
  end

  test "parse_args rejects llm api key provided via CLI flag" do
    assert {:error, "llm_api_key must be provided via MOM_LLM_API_KEY environment variable"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--llm-api-key",
               "key-from-flag"
             ])
  end

  test "parse_args accepts protected branch controls" do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-base-branch",
        "release",
        "--protected-branches",
        "main,release"
      ])

    assert config.github_base_branch == "release"
    assert config.protected_branches == ["main", "release"]
  end

  test "parse_args accepts allowed egress hosts flag" do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "api_openai",
        "--allowed-egress-hosts",
        "api.github.com,api.openai.com"
      ])

    assert config.allowed_egress_hosts == ["api.github.com", "api.openai.com"]
  end

  test "parse_args requires readiness gate approval for automated PR flows" do
    System.put_env("MOM_GITHUB_TOKEN", "token")

    assert {:error, "readiness_gate_approved must be true before enabling automated PR creation"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--github-repo",
               "acme/mom",
               "--actor-id",
               "mom-app[bot]",
               "--allowed-actor-ids",
               "mom-app[bot]"
             ])

    assert {:ok, config} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--github-repo",
               "acme/mom",
               "--actor-id",
               "mom-app[bot]",
               "--allowed-actor-ids",
               "mom-app[bot]",
               "--readiness-gate-approved"
             ])

    assert config.readiness_gate_approved
  after
    System.delete_env("MOM_GITHUB_TOKEN")
  end

  defp isolated_workdir_fixture do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "mom-task-policy-worktree-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, ".git"), "gitdir: /tmp/mom-task-policy-gitdir\n")
    workdir
  end
end
