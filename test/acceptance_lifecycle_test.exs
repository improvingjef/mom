defmodule Mom.AcceptanceLifecycleTest do
  use ExUnit.Case, async: true

  alias Mom.AcceptanceLifecycle

  test "finds lingering mix run acceptance descendants under a parent pid" do
    snapshot = """
    120 1 /usr/local/bin/node worker.js
    130 120 mix run acceptance/scripts/pipeline_acceptance.exs
    131 130 /opt/homebrew/Cellar/erlang/bin/beam.smp -- some args
    200 1 mix run acceptance/scripts/other_parent.exs
    """

    assert [child] = AcceptanceLifecycle.lingering_mix_run_children(snapshot, 120)
    assert child.pid == 130
    assert child.ppid == 120
    assert child.command =~ "mix run acceptance/scripts/pipeline_acceptance.exs"
  end

  test "ignores non-acceptance mix run descendants" do
    snapshot = """
    120 1 /usr/local/bin/node worker.js
    130 120 mix run scripts/dev_helper.exs
    131 130 /opt/homebrew/Cellar/erlang/bin/beam.smp -- some args
    """

    assert [] == AcceptanceLifecycle.lingering_mix_run_children(snapshot, 120)
  end

  test "computes descendant process tree from parsed rows" do
    rows = [
      %{pid: 10, ppid: 1, command: "node"},
      %{pid: 11, ppid: 10, command: "mix run acceptance/scripts/a.exs"},
      %{pid: 12, ppid: 11, command: "beam.smp"},
      %{pid: 20, ppid: 1, command: "node"}
    ]

    assert Enum.map(AcceptanceLifecycle.descendants(rows, 10), & &1.pid) == [11, 12]
  end

  test "defaults build artifact mode to worker-isolated and honors serialized env flags" do
    assert :worker_isolated == AcceptanceLifecycle.build_artifact_mode(%{})

    assert :serialized ==
             AcceptanceLifecycle.build_artifact_mode(%{
               "MOM_ACCEPTANCE_BUILD_MODE" => "serialized"
             })

    assert :serialized ==
             AcceptanceLifecycle.build_artifact_mode(%{"MOM_ACCEPTANCE_SERIALIZED" => "true"})

    assert :worker_isolated ==
             AcceptanceLifecycle.build_artifact_mode(%{"MOM_ACCEPTANCE_BUILD_MODE" => "unknown"})
  end

  test "builds deterministic sanitized build artifact paths" do
    assert "_build_acceptance_worker_ci-run_42_3" ==
             AcceptanceLifecycle.build_artifact_path(:worker_isolated, "ci-run#42", 3)

    assert "_build_acceptance_serialized_ci_run_42" ==
             AcceptanceLifecycle.build_artifact_path(:serialized, "ci run 42", 9)
  end

  test "merges lingering descendants across multiple snapshots for race hardening" do
    samples = [
      """
      120 1 node worker.js
      """,
      """
      120 1 node worker.js
      130 120 mix run acceptance/scripts/pipeline_acceptance.exs
      """
    ]

    assert [%{pid: 130}] =
             AcceptanceLifecycle.lingering_mix_run_children_from_samples(samples, 120)
  end

  test "parses retry budget and fail-on-flaky policy from env" do
    assert 3 == AcceptanceLifecycle.retry_budget(%{"MOM_ACCEPTANCE_RETRY_BUDGET" => "3"})
    assert 1 == AcceptanceLifecycle.retry_budget(%{"MOM_ACCEPTANCE_RETRY_BUDGET" => "invalid"})
    assert AcceptanceLifecycle.fail_on_flaky?(%{"MOM_ACCEPTANCE_FAIL_ON_FLAKY" => "true"})
    refute AcceptanceLifecycle.fail_on_flaky?(%{})
  end

  test "classifies monitor attach race failures and applies retry budget policy" do
    assert :monitor_attach_race ==
             AcceptanceLifecycle.classify_failure("missing telemetry failed pipeline event")

    assert :monitor_attach_race ==
             AcceptanceLifecycle.classify_failure("spawnSync mix ETIMEDOUT")

    assert :non_retryable ==
             AcceptanceLifecycle.classify_failure("syntax error in acceptance script")

    assert AcceptanceLifecycle.retry?(1, 2, :monitor_attach_race)
    refute AcceptanceLifecycle.retry?(3, 2, :monitor_attach_race)
    refute AcceptanceLifecycle.retry?(1, 2, :non_retryable)
  end

  test "parses post-suite bounded shutdown timeout from env" do
    assert 2_500 ==
             AcceptanceLifecycle.post_suite_shutdown_timeout_ms(%{
               "MOM_ACCEPTANCE_POST_SUITE_SHUTDOWN_TIMEOUT_MS" => "2500"
             })

    assert 2_000 ==
             AcceptanceLifecycle.post_suite_shutdown_timeout_ms(%{
               "MOM_ACCEPTANCE_POST_SUITE_SHUTDOWN_TIMEOUT_MS" => "invalid"
             })

    assert 2_000 == AcceptanceLifecycle.post_suite_shutdown_timeout_ms(%{})
  end

  test "adapts runner_burst acceptance timeout budget by attempt and worker index" do
    env = %{"TEST_WORKER_INDEX" => "2"}

    assert 130_000 ==
             AcceptanceLifecycle.acceptance_timeout_ms(
               "acceptance/scripts/runner_burst_acceptance.exs",
               1,
               env,
               120_000
             )

    assert 160_000 ==
             AcceptanceLifecycle.acceptance_timeout_ms(
               "acceptance/scripts/runner_burst_acceptance.exs",
               2,
               env,
               120_000
             )

    assert 120_000 ==
             AcceptanceLifecycle.acceptance_timeout_ms(
               "acceptance/scripts/pipeline_acceptance.exs",
               2,
               env,
               120_000
             )
  end

  test "computes deterministic retry backoff only for runner_burst acceptance" do
    env = %{"TEST_WORKER_INDEX" => "3"}

    assert 400 ==
             AcceptanceLifecycle.retry_backoff_ms(
               "acceptance/scripts/runner_burst_acceptance.exs",
               1,
               env
             )

    assert 900 ==
             AcceptanceLifecycle.retry_backoff_ms(
               "acceptance/scripts/runner_burst_acceptance.exs",
               2,
               env
             )

    assert 0 ==
             AcceptanceLifecycle.retry_backoff_ms(
               "acceptance/scripts/pipeline_acceptance.exs",
               2,
               env
             )
  end

  test "detects lingering orphaned acceptance mix run children from snapshot samples" do
    samples = [
      """
      400 1 node playwright
      401 400 node worker
      500 999 mix run acceptance/scripts/pipeline_acceptance.exs
      600 500 /opt/homebrew/Cellar/erlang/bin/beam.smp -- args
      """
    ]

    assert [%{pid: 500}] =
             AcceptanceLifecycle.orphaned_lingering_mix_run_children_from_samples(samples)
  end

  test "prunes stale ephemeral build artifact directories by retention policy" do
    root =
      Path.join(
        System.tmp_dir!(),
        "mom-acceptance-lifecycle-prune-#{System.unique_integer([:positive])}"
      )

    stale_runner = Path.join(root, "_build_runner_burst_stale")
    stale_worker = Path.join(root, "_build_acceptance_worker_stale_0")
    fresh_worker = Path.join(root, "_build_acceptance_worker_fresh_0")
    keep_other = Path.join(root, "_build_kept_other")

    on_exit(fn -> File.rm_rf!(root) end)

    File.rm_rf!(root)
    File.mkdir_p!(stale_runner)
    File.mkdir_p!(stale_worker)
    File.mkdir_p!(fresh_worker)
    File.mkdir_p!(keep_other)

    now = System.os_time(:second)
    set_directory_mtime!(stale_runner, now - 3_600)
    set_directory_mtime!(stale_worker, now - 3_600)
    set_directory_mtime!(fresh_worker, now)

    assert {:ok, summary} =
             AcceptanceLifecycle.prune_ephemeral_build_artifacts(
               root,
               retention_seconds: 300,
               keep_latest: 1
             )

    assert summary.candidates == 3
    assert "_build_acceptance_worker_fresh_0" in summary.kept
    assert "_build_runner_burst_stale" in summary.removed
    assert "_build_acceptance_worker_stale_0" in summary.removed
    assert File.dir?(fresh_worker)
    refute File.exists?(stale_runner)
    refute File.exists?(stale_worker)
    assert File.dir?(keep_other)
  end

  defp set_directory_mtime!(path, unix_seconds) do
    datetime = :calendar.system_time_to_local_time(unix_seconds, :second)
    :ok = :file.change_time(String.to_charlist(path), datetime)
  end
end
