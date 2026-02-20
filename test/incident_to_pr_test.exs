defmodule Mom.IncidentToPrTest do
  use ExUnit.Case, async: true

  alias Mom.IncidentToPr

  test "reports success when incident-to-PR audit steps are complete and ordered" do
    events = [
      {[:mom, :audit, :github_issue_created],
       %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_applied],
       %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]

    assert {:ok, signal} = IncidentToPr.evaluate(events)
    assert signal.success
    assert signal.pr_number == 11
    assert signal.branch == "mom/1"
    assert signal.missing_steps == []
    assert signal.out_of_order_steps == []
    assert signal.stop_point_classification == %{
             detect: :passed,
             patch_apply: :passed,
             tests: :passed,
             push: :passed,
             pr_create: :passed
           }
    assert signal.failure_stop_point == nil
  end

  test "reports failure when required audit events are missing" do
    events = [
      {[:mom, :audit, :github_issue_created],
       %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_applied],
       %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]

    assert {:error, signal} = IncidentToPr.evaluate(events)
    assert signal.success == false
    assert signal.missing_steps == [:tests_passed]
    assert signal.stop_point_classification.tests == :missing
    assert signal.failure_stop_point == :tests
  end

  test "reports failure when tests fail even if pr is created" do
    events = [
      {[:mom, :audit, :github_issue_created],
       %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_applied],
       %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "error"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]

    assert {:error, signal} = IncidentToPr.evaluate(events)
    assert signal.success == false
    assert signal.tests_status_ok == false
    assert signal.stop_point_classification.tests == :failed
    assert signal.failure_stop_point == :tests
  end

  test "classifies each stop point failure from audit stream" do
    scenarios = [
      {:detect,
       [
         {[:mom, :audit, :github_issue_failed], %{repo: "acme/mom", actor_id: "bot"}},
         {[:mom, :audit, :git_patch_applied],
          %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
         {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
         {[:mom, :audit, :github_pr_created],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
       ]},
      {:patch_apply,
       [
         {[:mom, :audit, :github_issue_created],
          %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
         {[:mom, :audit, :git_patch_failed], %{repo: "acme/mom", actor_id: "bot"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
         {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
         {[:mom, :audit, :github_pr_created],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
       ]},
      {:tests,
       [
         {[:mom, :audit, :github_issue_created],
          %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
         {[:mom, :audit, :git_patch_applied],
          %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "error"}},
         {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
         {[:mom, :audit, :github_pr_created],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
       ]},
      {:push,
       [
         {[:mom, :audit, :github_issue_created],
          %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
         {[:mom, :audit, :git_patch_applied],
          %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
         {[:mom, :audit, :git_branch_push_failed], %{repo: "acme/mom", actor_id: "bot"}},
         {[:mom, :audit, :github_pr_created],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
       ]},
      {:pr_create,
       [
         {[:mom, :audit, :github_issue_created],
          %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
         {[:mom, :audit, :git_patch_applied],
          %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
         {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
         {[:mom, :audit, :github_pr_failed], %{repo: "acme/mom", actor_id: "bot"}}
       ]}
    ]

    Enum.each(scenarios, fn {stop_point, events} ->
      assert {:error, signal} = IncidentToPr.evaluate(events)
      assert signal.stop_point_classification[stop_point] == :failed
      assert signal.failure_stop_point == stop_point
    end)
  end

  test "persists incident-to-PR stop-point summary artifact for a run id" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "mom-incident-to-pr-artifacts-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(artifact_dir) end)

    signal = %{
      success: true,
      missing_steps: [],
      out_of_order_steps: [],
      tests_status_ok: true,
      branch_matches: true,
      branch: "mom/1",
      pr_number: 11,
      stop_point_classification: %{
        detect: :passed,
        patch_apply: :passed,
        tests: :passed,
        push: :passed,
        pr_create: :passed
      },
      failure_stop_point: nil
    }

    assert {:ok, path} =
             IncidentToPr.persist_summary_artifact(signal, run_id: "run-123", artifact_dir: artifact_dir)

    assert File.exists?(path)
    assert String.ends_with?(path, "run-123.json")

    assert {:ok, payload} =
             path
             |> File.read!()
             |> Jason.decode()

    assert payload["run_id"] == "run-123"
    assert payload["signal"]["success"] == true
    assert payload["signal"]["stop_point_classification"]["tests"] == "passed"
    assert is_integer(payload["recorded_at_unix"])
  end

  test "enforces immutability by rejecting overwrite for existing run artifact" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "mom-incident-to-pr-artifacts-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(artifact_dir) end)

    signal = %{
      success: false,
      missing_steps: [:tests_passed],
      out_of_order_steps: [],
      tests_status_ok: false,
      branch_matches: false,
      branch: nil,
      pr_number: nil,
      stop_point_classification: %{
        detect: :passed,
        patch_apply: :passed,
        tests: :failed,
        push: :missing,
        pr_create: :missing
      },
      failure_stop_point: :tests
    }

    assert {:ok, _path} =
             IncidentToPr.persist_summary_artifact(signal, run_id: "immutable-run", artifact_dir: artifact_dir)

    assert {:error, :already_exists} =
             IncidentToPr.persist_summary_artifact(signal, run_id: "immutable-run", artifact_dir: artifact_dir)
  end

  test "validates recent successful canary evidence with push and PR URL proof" do
    artifact_path =
      Path.join(
        System.tmp_dir!(),
        "mom-incident-to-pr-canary-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm_rf!(artifact_path) end)

    payload = %{
      run_id: "canary-123",
      recorded_at_unix: 1_000,
      signal: %{
        success: true,
        pr_number: 42,
        pr_url: "https://example/pull/42",
        stop_point_classification: %{push: :passed, pr_create: :passed}
      }
    }

    File.write!(artifact_path, Jason.encode!(payload) <> "\n")

    assert {:ok, evidence} =
             IncidentToPr.validate_recent_canary_run(
               artifact_path: artifact_path,
               now_unix: 1_200,
               max_age_seconds: 600
             )

    assert evidence.run_id == "canary-123"
    assert evidence.pr_number == 42
    assert evidence.pr_url == "https://example/pull/42"
    assert evidence.age_seconds == 200
  end

  test "rejects stale or incomplete canary evidence" do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "mom-incident-to-pr-canary-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base_dir) end)
    File.mkdir_p!(base_dir)

    stale_path = Path.join(base_dir, "stale.json")

    File.write!(
      stale_path,
      Jason.encode!(%{
        run_id: "old",
        recorded_at_unix: 10,
        signal: %{
          success: true,
          pr_number: 9,
          pr_url: "https://example/pull/9",
          stop_point_classification: %{push: :passed, pr_create: :passed}
        }
      }) <> "\n"
    )

    assert {:error, {:stale_canary_evidence, %{age_seconds: 990, max_age_seconds: 300}}} =
             IncidentToPr.validate_recent_canary_run(
               artifact_path: stale_path,
               now_unix: 1_000,
               max_age_seconds: 300
             )

    incomplete_path = Path.join(base_dir, "incomplete.json")

    File.write!(
      incomplete_path,
      Jason.encode!(%{
        run_id: "incomplete",
        recorded_at_unix: 1_000,
        signal: %{
          success: true,
          pr_number: 9,
          stop_point_classification: %{push: :passed, pr_create: :passed}
        }
      }) <> "\n"
    )

    assert {:error, :missing_pr_url_evidence} =
             IncidentToPr.validate_recent_canary_run(
               artifact_path: incomplete_path,
               now_unix: 1_100,
               max_age_seconds: 600
             )
  end
end
