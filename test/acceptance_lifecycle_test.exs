defmodule Mom.AcceptanceLifecycleTest do
  use ExUnit.Case, async: true

  alias Mom.AcceptanceLifecycle

  test "finds lingering mix run acceptance descendants under a parent pid" do
    snapshot = """
    120 1 /usr/local/bin/node worker.js
    130 120 mix run acceptance/scripts/pipeline_acceptance.exs
    131 130 /opt/homebrew/Cellar/erlang/bin/beam.smp -- some args
    200 1 mix run acceptance/scripts/other_parent.exs
    """

    assert [child] = AcceptanceLifecycle.lingering_mix_run_children(snapshot, 120)
    assert child.pid == 130
    assert child.ppid == 120
    assert child.command =~ "mix run acceptance/scripts/pipeline_acceptance.exs"
  end

  test "ignores non-acceptance mix run descendants" do
    snapshot = """
    120 1 /usr/local/bin/node worker.js
    130 120 mix run scripts/dev_helper.exs
    131 130 /opt/homebrew/Cellar/erlang/bin/beam.smp -- some args
    """

    assert [] == AcceptanceLifecycle.lingering_mix_run_children(snapshot, 120)
  end

  test "computes descendant process tree from parsed rows" do
    rows = [
      %{pid: 10, ppid: 1, command: "node"},
      %{pid: 11, ppid: 10, command: "mix run acceptance/scripts/a.exs"},
      %{pid: 12, ppid: 11, command: "beam.smp"},
      %{pid: 20, ppid: 1, command: "node"}
    ]

    assert Enum.map(AcceptanceLifecycle.descendants(rows, 10), & &1.pid) == [11, 12]
  end

  test "defaults build artifact mode to worker-isolated and honors serialized env flags" do
    assert :worker_isolated == AcceptanceLifecycle.build_artifact_mode(%{})
    assert :serialized == AcceptanceLifecycle.build_artifact_mode(%{"MOM_ACCEPTANCE_BUILD_MODE" => "serialized"})
    assert :serialized == AcceptanceLifecycle.build_artifact_mode(%{"MOM_ACCEPTANCE_SERIALIZED" => "true"})
    assert :worker_isolated == AcceptanceLifecycle.build_artifact_mode(%{"MOM_ACCEPTANCE_BUILD_MODE" => "unknown"})
  end

  test "builds deterministic sanitized build artifact paths" do
    assert "_build_acceptance_worker_ci-run_42_3" ==
             AcceptanceLifecycle.build_artifact_path(:worker_isolated, "ci-run#42", 3)

    assert "_build_acceptance_serialized_ci_run_42" ==
             AcceptanceLifecycle.build_artifact_path(:serialized, "ci run 42", 9)
  end
end
