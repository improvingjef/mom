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
  end

  test "parses redact keys from comma-separated string" do
    {:ok, config} =
      Config.from_opts(repo: "/tmp/repo", redact_keys: "foo, Bar , ,baz")

    assert config.redact_keys == ["foo", "Bar", "baz"]
  end

  test "uses runtime env defaults" do
    Application.put_env(:mom, :llm_cmd, "cat")
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert config.llm_cmd == "cat"
  after
    Application.delete_env(:mom, :llm_cmd)
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
end
