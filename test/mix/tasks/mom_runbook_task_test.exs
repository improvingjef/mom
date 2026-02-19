defmodule Mix.Tasks.MomRunbookTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "parse_args accepts output path and generated_on" do
    assert {:ok, opts} =
             Mix.Tasks.Mom.Runbook.parse_args([
               "--output",
               "docs/dr.md",
               "--generated-on",
               "2026-02-19"
             ])

    assert opts.output == "docs/dr.md"
    assert opts.generated_on == "2026-02-19"
  end

  test "parse_args defaults output path" do
    assert {:ok, opts} = Mix.Tasks.Mom.Runbook.parse_args([])

    assert opts.output == "docs/disaster_recovery_runbook.md"
  end

  test "run writes a validated runbook file" do
    output_path =
      Path.join(System.tmp_dir!(), "mom-runbook-#{System.unique_integer([:positive])}.md")

    on_exit(fn -> File.rm(output_path) end)

    output =
      capture_io(fn ->
        Mix.Tasks.Mom.Runbook.run(["--output", output_path, "--generated-on", "2026-02-19"])
      end)

    assert String.contains?(output, "wrote disaster recovery runbook")

    markdown = File.read!(output_path)
    assert String.contains?(markdown, "## Backup and Restore")
    assert String.contains?(markdown, "## Credential Revocation Drill")
    assert String.contains?(markdown, "## Failover Steps")
  end
end
