defmodule Mom.RunbookTest do
  use ExUnit.Case, async: true

  alias Mom.Runbook

  test "render returns markdown with required disaster recovery sections" do
    markdown = Runbook.render("2026-02-19")

    assert String.contains?(markdown, "# Mom Disaster Recovery Runbook")
    assert String.contains?(markdown, "## Backup and Restore")
    assert String.contains?(markdown, "## Credential Revocation Drill")
    assert String.contains?(markdown, "## Failover Steps")
    assert String.contains?(markdown, "## Temp Worktree Saturation Response")
    assert String.contains?(markdown, "Generated on: 2026-02-19")
  end

  test "validate confirms required sections are present" do
    markdown = Runbook.render("2026-02-19")

    assert :ok = Runbook.validate(markdown)
  end

  test "validate reports missing sections" do
    assert {:error, missing} =
             Runbook.validate("# Mom Disaster Recovery Runbook\n\n## Backup and Restore\n")

    assert "Credential Revocation Drill" in missing
    assert "Failover Steps" in missing
    assert "Temp Worktree Saturation Response" in missing
  end
end
