defmodule Mix.Tasks.Mom.HarnessTaskTest do
  use ExUnit.Case, async: true

  test "parse_args accepts repo, record path, and baseline scenario paths" do
    assert {:ok, opts} =
             Mix.Tasks.Mom.Harness.parse_args([
               "--repo",
               "acme/harness",
               "--record-path",
               "acceptance/harness_repo.json",
               "--baseline-error-path",
               "priv/replay/error_path.ex",
               "--baseline-diagnostics-path",
               "priv/replay/diagnostics_path.ex"
             ])

    assert opts.repo == "acme/harness"
    assert opts.record_path == "acceptance/harness_repo.json"
    assert opts.baseline_error_path == "priv/replay/error_path.ex"
    assert opts.baseline_diagnostics_path == "priv/replay/diagnostics_path.ex"
  end

  test "parse_args requires repo" do
    assert {:error, "--repo is required"} = Mix.Tasks.Mom.Harness.parse_args([])
  end

  test "parse_args requires baseline scenario paths" do
    assert {:error, "--baseline-error-path is required"} =
             Mix.Tasks.Mom.Harness.parse_args(["--repo", "acme/harness"])

    assert {:error, "--baseline-diagnostics-path is required"} =
             Mix.Tasks.Mom.Harness.parse_args([
               "--repo",
               "acme/harness",
               "--baseline-error-path",
               "priv/replay/error_path.ex"
             ])
  end
end
