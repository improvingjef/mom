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
         {[:mom, :audit, :git_branch_pushed],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
         {[:mom, :audit, :github_pr_created],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
       ]},
      {:patch_apply,
       [
         {[:mom, :audit, :github_issue_created],
          %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
         {[:mom, :audit, :git_patch_failed], %{repo: "acme/mom", actor_id: "bot"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
         {[:mom, :audit, :git_branch_pushed],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
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
         {[:mom, :audit, :git_branch_pushed],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
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
         {[:mom, :audit, :git_branch_pushed],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
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
      Path.join(
        System.tmp_dir!(),
        "mom-incident-to-pr-artifacts-#{System.unique_integer([:positive])}"
      )

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
             IncidentToPr.persist_summary_artifact(signal,
               run_id: "run-123",
               artifact_dir: artifact_dir
             )

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
      Path.join(
        System.tmp_dir!(),
        "mom-incident-to-pr-artifacts-#{System.unique_integer([:positive])}"
      )

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
             IncidentToPr.persist_summary_artifact(signal,
               run_id: "immutable-run",
               artifact_dir: artifact_dir
             )

    assert {:error, :already_exists} =
             IncidentToPr.persist_summary_artifact(signal,
               run_id: "immutable-run",
               artifact_dir: artifact_dir
             )
  end

  test "persists signed integrity attestation and verifies replay payload" do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "mom-incident-to-pr-artifacts-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(artifact_dir) end)

    signing_key = "incident-to-pr-signing-key"

    signal = %{
      success: true,
      missing_steps: [],
      out_of_order_steps: [],
      tests_status_ok: true,
      branch_matches: true,
      branch: "mom/1",
      pr_number: 11,
      pr_url: "https://example/pull/11",
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
             IncidentToPr.persist_summary_artifact(
               signal,
               run_id: "signed-run",
               artifact_dir: artifact_dir,
               attestation_signing_key: signing_key
             )

    assert {:ok, replayed_payload} =
             IncidentToPr.replay_summary_artifact(path,
               attestation_signing_key: signing_key,
               verify_attestation: true
             )

    assert replayed_payload["integrity"]["content_sha256"] != nil
    assert replayed_payload["integrity"]["signature"] != nil
    assert replayed_payload["integrity"]["signer_key_id"] =~ "sha256:"
  end

  test "rejects replay when signed summary artifact is tampered" do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "mom-incident-to-pr-artifacts-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(artifact_dir) end)

    signing_key = "incident-to-pr-signing-key"

    signal = %{
      success: true,
      missing_steps: [],
      out_of_order_steps: [],
      tests_status_ok: true,
      branch_matches: true,
      branch: "mom/1",
      pr_number: 11,
      pr_url: "https://example/pull/11",
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
             IncidentToPr.persist_summary_artifact(
               signal,
               run_id: "tampered-run",
               artifact_dir: artifact_dir,
               attestation_signing_key: signing_key
             )

    payload = path |> File.read!() |> Jason.decode!()

    tampered = put_in(payload, ["signal", "pr_url"], "https://example/pull/999")
    File.write!(path, Jason.encode!(tampered) <> "\n")

    assert {:error, :invalid_artifact_attestation} =
             IncidentToPr.replay_summary_artifact(path,
               attestation_signing_key: signing_key,
               verify_attestation: true
             )
  end

  test "validates recent successful canary evidence with push and PR URL proof" do
    artifact_path =
      Path.join(
        System.tmp_dir!(),
        "mom-incident-to-pr-canary-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm_rf!(artifact_path) end)

    signing_key = "incident-to-pr-signing-key"

    payload = %{
      "run_id" => "canary-123",
      "recorded_at_unix" => 1_000,
      "signal" => %{
        "success" => true,
        "pr_number" => 42,
        "pr_url" => "https://example/pull/42",
        "stop_point_classification" => %{"push" => "passed", "pr_create" => "passed"}
      }
    }

    write_signed_artifact!(artifact_path, payload, signing_key)

    assert {:ok, evidence} =
             IncidentToPr.validate_recent_canary_run(
               artifact_path: artifact_path,
               now_unix: 1_200,
               max_age_seconds: 600,
               attestation_signing_key: signing_key,
               verify_attestation: true
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
    signing_key = "incident-to-pr-signing-key"

    write_signed_artifact!(
      stale_path,
      %{
        "run_id" => "old",
        "recorded_at_unix" => 10,
        "signal" => %{
          "success" => true,
          "pr_number" => 9,
          "pr_url" => "https://example/pull/9",
          "stop_point_classification" => %{"push" => "passed", "pr_create" => "passed"}
        }
      },
      signing_key
    )

    assert {:error, {:stale_canary_evidence, %{age_seconds: 990, max_age_seconds: 300}}} =
             IncidentToPr.validate_recent_canary_run(
               artifact_path: stale_path,
               now_unix: 1_000,
               max_age_seconds: 300,
               attestation_signing_key: signing_key,
               verify_attestation: true
             )

    incomplete_path = Path.join(base_dir, "incomplete.json")

    write_signed_artifact!(
      incomplete_path,
      %{
        "run_id" => "incomplete",
        "recorded_at_unix" => 1_000,
        "signal" => %{
          "success" => true,
          "pr_number" => 9,
          "stop_point_classification" => %{"push" => "passed", "pr_create" => "passed"}
        }
      },
      signing_key
    )

    assert {:error, :missing_pr_url_evidence} =
             IncidentToPr.validate_recent_canary_run(
               artifact_path: incomplete_path,
               now_unix: 1_100,
               max_age_seconds: 600,
               attestation_signing_key: signing_key,
               verify_attestation: true
             )
  end

  defp write_signed_artifact!(path, payload, signing_key) do
    encoded_content =
      payload
      |> normalize_integrity_term()
      |> :erlang.term_to_binary()

    content_sha256 = :crypto.hash(:sha256, encoded_content) |> Base.encode16(case: :lower)

    key_id =
      signing_key
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> then(&("sha256:" <> &1))

    signature =
      :crypto.mac(:hmac, :sha256, signing_key, encoded_content)
      |> Base.encode64()

    signed_payload =
      Map.put(payload, "integrity", %{
        "content_sha256" => content_sha256,
        "signer_key_id" => key_id,
        "signature" => signature
      })

    File.write!(path, Jason.encode!(signed_payload) <> "\n")
  end

  defp normalize_integrity_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} ->
      {normalize_integrity_key(key), normalize_integrity_term(nested)}
    end)
    |> Enum.sort_by(fn {key, _nested} -> key end)
  end

  defp normalize_integrity_term(value) when is_list(value),
    do: Enum.map(value, &normalize_integrity_term/1)

  defp normalize_integrity_term(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp normalize_integrity_term(value), do: value

  defp normalize_integrity_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_integrity_key(key), do: key
end
