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
end
