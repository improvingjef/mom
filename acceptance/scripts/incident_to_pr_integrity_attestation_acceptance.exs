defmodule Mom.Acceptance.IncidentToPrIntegrityAttestationScript do
  alias Mom.IncidentToPr

  def run do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "mom-incident-to-pr-integrity-attestation-#{System.unique_integer([:positive])}"
      )

    try do
      File.rm_rf!(artifact_dir)
      File.mkdir_p!(artifact_dir)

      signing_key = "incident-to-pr-acceptance-signing-key"

      signal = %{
        success: true,
        missing_steps: [],
        out_of_order_steps: [],
        tests_status_ok: true,
        branch_matches: true,
        branch: "mom/acceptance-42",
        pr_number: 42,
        pr_url: "https://example/pull/42",
        stop_point_classification: %{
          detect: :passed,
          patch_apply: :passed,
          tests: :passed,
          push: :passed,
          pr_create: :passed
        },
        failure_stop_point: nil
      }

      {:ok, path} =
        IncidentToPr.persist_summary_artifact(
          signal,
          run_id: "integrity-run-42",
          artifact_dir: artifact_dir,
          attestation_signing_key: signing_key
        )

      {:ok, payload} =
        path
        |> File.read!()
        |> Jason.decode()

      replay_verified? =
        case IncidentToPr.replay_summary_artifact(path,
               verify_attestation: true,
               attestation_signing_key: signing_key
             ) do
          {:ok, _payload} -> true
          _ -> false
        end

      tampered_payload = put_in(payload, ["signal", "pr_number"], 77)
      File.write!(path, Jason.encode!(tampered_payload) <> "\n")

      tamper_rejected? =
        case IncidentToPr.replay_summary_artifact(path,
               verify_attestation: true,
               attestation_signing_key: signing_key
             ) do
          {:error, :invalid_artifact_attestation} -> true
          _ -> false
        end

      IO.puts(
        "RESULT_JSON:" <>
          Jason.encode!(%{
            persisted: File.exists?(path),
            integrity_present: is_map(payload["integrity"]),
            replay_verified: replay_verified?,
            tamper_rejected: tamper_rejected?
          })
      )
    after
      File.rm_rf!(artifact_dir)
    end
  end
end

Mom.Acceptance.IncidentToPrIntegrityAttestationScript.run()
