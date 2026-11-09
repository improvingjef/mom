defmodule Mom.TargetsTriageTest do
  use ExUnit.Case, async: true

  alias Mom.Targets.{RecordOnly, ReportOnly, Target, Watcher}

  defp opts(triage),
    do:
      Watcher.runner_opts(%Target{name: "school", node: :"school@127.0.0.1", triage: triage}, [])

  test "off records only; report diagnoses without a fix; fix uses the engine" do
    assert opts(:off)[:worker_module] == RecordOnly
    assert opts(:report)[:worker_opts][:engine_module] == ReportOnly
    refute Keyword.has_key?(opts(:fix), :worker_module)
    refute Keyword.has_key?(opts(:fix), :worker_opts)
  end

  test "report never prepares a workdir or a patch" do
    {:ok, src} = File.read("lib/mom/core/engine.ex")
    [_, body] = Regex.run(~r/def report_log\(.*?\n  end\n/s, src) |> then(&[nil, hd(&1)])
    refute body =~ "prepare_workdir"
    refute body =~ "generate_patch"
  end
end
