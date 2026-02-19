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
    assert config.job_timeout_ms == 120_000
    assert config.overflow_policy == :drop_newest
    assert "api.github.com" in config.allowed_egress_hosts
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

  test "parses pipeline concurrency values from opts" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        max_concurrency: 8,
        queue_max_size: 350,
        job_timeout_ms: 9_000,
        overflow_policy: :drop_oldest
      )

    assert config.max_concurrency == 8
    assert config.queue_max_size == 350
    assert config.job_timeout_ms == 9_000
    assert config.overflow_policy == :drop_oldest
  end

  test "validates pipeline concurrency values" do
    assert {:error, "max_concurrency must be a non-negative integer"} =
             Config.from_opts(repo: "/tmp/repo", max_concurrency: -1)

    assert {:error, "queue_max_size must be a positive integer"} =
             Config.from_opts(repo: "/tmp/repo", queue_max_size: 0)

    assert {:error, "job_timeout_ms must be a positive integer"} =
             Config.from_opts(repo: "/tmp/repo", job_timeout_ms: 0)

    assert {:error, "overflow_policy must be :drop_newest or :drop_oldest"} =
             Config.from_opts(repo: "/tmp/repo", overflow_policy: :drop_middle)
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
end
