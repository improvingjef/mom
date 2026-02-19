defmodule Mom.Acceptance.MomCliComplianceScript do
  alias Mix.Tasks.Mom, as: MomTask

  def run do
    _ = Application.ensure_all_started(:ex_unit)

    evidence_path =
      Path.join(System.tmp_dir!(), "mom-compliance-evidence-#{System.unique_integer([:positive])}.jsonl")

    File.rm_rf!(evidence_path)
    old_record = Jason.encode!(%{"recorded_at_unix" => 1, "event" => "old"})
    File.write!(evidence_path, old_record <> "\n")

    {:ok, config} =
      MomTask.parse_args([
        "/tmp/repo",
        "--audit-retention-days",
        "1",
        "--soc2-evidence-path",
        evidence_path,
        "--pii-handling-policy",
        "drop"
      ])

    Application.put_env(:mom, :audit_retention_days, config.audit_retention_days)
    Application.put_env(:mom, :soc2_evidence_path, config.soc2_evidence_path)
    Application.put_env(:mom, :pii_handling_policy, config.pii_handling_policy)

    :ok =
      Mom.Audit.emit(:github_issue_failed, %{
        repo: "acme/mom",
        token: "ghp_123",
        nested: %{authorization: "Bearer abc"},
        safe: "ok"
      })

    log_payload =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok =
          Mom.Audit.emit(:github_issue_created, %{
            repo: "acme/mom",
            token: "ghp_456",
            nested: %{authorization: "Bearer def"},
            safe: "ok-2"
          })
      end)

    evidence_lines =
      evidence_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    result = %{
      audit_retention_days: config.audit_retention_days,
      soc2_evidence_path_set: config.soc2_evidence_path == evidence_path,
      pii_handling_policy: Atom.to_string(config.pii_handling_policy),
      has_old_record: Enum.any?(evidence_lines, &(&1["event"] == "old")),
      has_new_record: Enum.any?(evidence_lines, &(&1["event"] == "github_issue_created")),
      evidence_redacted_token:
        Enum.any?(evidence_lines, &Map.get(&1, "token") == "[REDACTED]"),
      evidence_has_token_key: Enum.any?(evidence_lines, &Map.has_key?(&1, "token")),
      evidence_has_authorization_key:
        Enum.any?(evidence_lines, fn line ->
          case line["nested"] do
            %{"authorization" => _} -> true
            _ -> false
          end
        end),
      log_has_token_key: String.contains?(log_payload, "\"token\":"),
      log_has_authorization_key: String.contains?(log_payload, "\"authorization\":"),
      log_contains_secret: String.contains?(log_payload, "ghp_456")
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end
end

Mom.Acceptance.MomCliComplianceScript.run()
