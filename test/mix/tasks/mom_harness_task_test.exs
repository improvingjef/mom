defmodule Mix.Tasks.Mom.HarnessTaskTest do
  use ExUnit.Case, async: true

  test "parse_args accepts repo and record path" do
    assert {:ok, opts} =
             Mix.Tasks.Mom.Harness.parse_args([
               "--repo",
               "acme/harness",
               "--record-path",
               "acceptance/harness_repo.json"
             ])

    assert opts.repo == "acme/harness"
    assert opts.record_path == "acceptance/harness_repo.json"
  end

  test "parse_args requires repo" do
    assert {:error, "--repo is required"} = Mix.Tasks.Mom.Harness.parse_args([])
  end
end
