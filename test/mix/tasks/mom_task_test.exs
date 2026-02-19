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
end
