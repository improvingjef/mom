defmodule Mom.Config2Test do
  use ExUnit.Case

  alias Mom.Config2

  test "builds nested config from configured modules" do
    assert {:ok, config} = Config2.from_opts(repo: "/tmp/repo")
    assert config.runtime.repo == "/tmp/repo"
    assert config.runtime.poll_interval_ms == 5_000
    assert config.pipeline.queue_max_size == 200
    assert config.compliance.github_live_permission_verification == false
  end

  test "applies runtime struct <- cli override for policy structs" do
    assert {:ok, config} = Config2.from_opts(repo: "/tmp/repo", poll_interval_ms: 9000)
    assert config.runtime.poll_interval_ms == 9000
  end

  test "applies policy-specific cli overrides" do
    assert {:ok, config} =
             Config2.from_opts(
               repo: "/tmp/repo",
               execution_profile: :production_hardened,
               provider: :codex,
               cmd: "codex exec --sandbox read-only",
               sandbox_mode: :read_only,
               command_allowlist: ["codex"],
               write_boundaries: [],
               open_pr: false,
               readiness_gate_approved: false
             )

    assert config.governance.execution_profile == :production_hardened
    assert config.llm.provider == :codex
  end
end
