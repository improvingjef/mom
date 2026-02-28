defmodule Mom.AuditComplianceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    keys = [:redact_keys, :pii_handling_policy, :soc2_evidence_path, :audit_retention_days]
    previous = Map.new(keys, &{&1, Application.get_env(:mom, &1)})

    on_exit(fn ->
      Enum.each(keys, fn key ->
        case Map.fetch!(previous, key) do
          nil -> Application.delete_env(:mom, key)
          value -> Application.put_env(:mom, key, value)
        end
      end)
    end)

    :ok
  end

  test "writes SOC2 evidence and enforces audit retention policy" do
    evidence_path =
      Path.join(
        System.tmp_dir!(),
        "mom-audit-evidence-#{System.unique_integer([:positive])}.jsonl"
      )

    File.rm_rf!(evidence_path)
    now = DateTime.utc_now() |> DateTime.to_unix()
    old_record = Jason.encode!(%{"recorded_at_unix" => now - 172_800, "event" => "old"})
    fresh_record = Jason.encode!(%{"recorded_at_unix" => now, "event" => "fresh"})
    File.write!(evidence_path, old_record <> "\n" <> fresh_record <> "\n")

    Application.put_env(:mom, :audit_retention_days, 1)
    Application.put_env(:mom, :soc2_evidence_path, evidence_path)

    :ok = Mom.Audit.emit(:github_issue_created, %{repo: "acme/mom", actor_id: "mom[bot]"})

    lines =
      evidence_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    refute Enum.any?(lines, &(&1["event"] == "old"))
    assert Enum.any?(lines, &(&1["event"] == "fresh"))

    assert Enum.any?(lines, fn line ->
             line["event"] == "github_issue_created" and
               line["repo"] == "acme/mom" and
               line["actor_id"] == "mom[bot]"
           end)
  end

  test "drop PII policy removes sensitive keys instead of redacting" do
    Application.put_env(:mom, :pii_handling_policy, :drop)
    Application.put_env(:mom, :redact_keys, ["token", "authorization"])

    log =
      capture_log(fn ->
        :ok =
          Mom.Audit.emit(:github_issue_failed, %{
            repo: "acme/mom",
            token: "ghp_123",
            nested: %{authorization: "Bearer abc"},
            safe: "ok"
          })
      end)

    assert log =~ "\"event\":\"github_issue_failed\""
    assert log =~ "\"safe\":\"ok\""
    refute log =~ "\"token\":"
    refute log =~ "\"authorization\":"
    refute log =~ "ghp_123"
    refute log =~ "Bearer abc"
    refute log =~ "[REDACTED]"
  end
end
