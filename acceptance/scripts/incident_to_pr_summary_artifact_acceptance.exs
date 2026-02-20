defmodule Mom.Acceptance.IncidentToPrSummaryArtifactScript do
  alias Mom.IncidentToPr

  def run do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "mom-incident-to-pr-summary-artifact-#{System.unique_integer([:positive])}"
      )

    try do
      File.rm_rf!(artifact_dir)
      File.mkdir_p!(artifact_dir)

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

      {:ok, path} =
        IncidentToPr.persist_summary_artifact(
          signal,
          run_id: "acceptance-run-42",
          artifact_dir: artifact_dir
        )

      immutable? =
        case IncidentToPr.persist_summary_artifact(
               signal,
               run_id: "acceptance-run-42",
               artifact_dir: artifact_dir
             ) do
          {:error, :already_exists} -> true
          _ -> false
        end

      {:ok, payload} =
        path
        |> File.read!()
        |> Jason.decode()

      IO.puts(
        "RESULT_JSON:" <>
          Jason.encode!(%{
            persisted: File.exists?(path),
            immutable: immutable?,
            payload: payload
          })
      )
    after
      File.rm_rf!(artifact_dir)
    end
  end
end

Mom.Acceptance.IncidentToPrSummaryArtifactScript.run()
