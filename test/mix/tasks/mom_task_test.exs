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
        "--job-timeout-ms",
        "45000",
        "--overflow-policy",
        "drop_oldest"
      ])

    assert config.mode == :inproc
    assert config.max_concurrency == 6
    assert config.queue_max_size == 333
    assert config.job_timeout_ms == 45_000
    assert config.overflow_policy == :drop_oldest
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
    assert {:error, "allowed_actor_ids must be set when github_token is configured"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--github-token",
               "token",
               "--actor-id",
               "mom-bot"
             ])

    assert {:ok, config} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--github-token",
               "token",
               "--actor-id",
               "mom-bot",
               "--allowed-actor-ids",
               "mom-bot,mom-staging"
             ])

    assert config.allowed_actor_ids == ["mom-bot", "mom-staging"]
  end

  test "parse_args rejects non-machine actor identities for github credentials" do
    assert {:error, "actor_id must be a dedicated machine identity"} =
             Mix.Tasks.Mom.parse_args([
               "/tmp/repo",
               "--github-token",
               "token",
               "--actor-id",
               "jef",
               "--allowed-actor-ids",
               "jef"
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
end
