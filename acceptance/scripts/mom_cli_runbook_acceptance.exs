defmodule Mom.Acceptance.MomCliRunbookScript do
  alias Mix.Tasks.Mom.Runbook, as: RunbookTask

  def run do
    output_path =
      Path.join(
        System.tmp_dir!(),
        "mom-disaster-recovery-runbook-#{System.unique_integer([:positive])}.md"
      )

    File.rm_rf!(output_path)

    RunbookTask.run(["--output", output_path, "--generated-on", "2026-02-19"])

    markdown = File.read!(output_path)

    result = %{
      output_exists: File.exists?(output_path),
      generated_on_present: String.contains?(markdown, "Generated on: 2026-02-19"),
      has_backup_restore: String.contains?(markdown, "## Backup and Restore"),
      has_credential_revocation: String.contains?(markdown, "## Credential Revocation Drill"),
      has_failover: String.contains?(markdown, "## Failover Steps"),
      validates: Mom.Runbook.validate(markdown) == :ok
    }

    File.rm_rf!(output_path)

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end
end

Mom.Acceptance.MomCliRunbookScript.run()
