defmodule Mom.DiagnosticsTest do
  use ExUnit.Case

  alias Mom.{Config, Diagnostics}

  test "poll triggers triage when thresholds exceeded" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        mode: :inproc,
        triage_on_diagnostics: true,
        diag_mem_high_bytes: 0,
        diag_cooldown_ms: 0
      )

    last = System.monotonic_time(:millisecond) - 10_000
    {_report, issues, trigger?, _now} = Diagnostics.poll(config, last)
    assert issues != []
    assert trigger? == true
  end

  test "poll respects cooldown" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        mode: :inproc,
        triage_on_diagnostics: true,
        diag_mem_high_bytes: 0,
        diag_cooldown_ms: 10_000
      )

    now = System.monotonic_time(:millisecond)
    {_report, _issues, trigger?, _now} = Diagnostics.poll(config, now)
    assert trigger? == false
  end

  test "hot_processes returns tuples" do
    list = Diagnostics.hot_processes(3)
    assert is_list(list)

    Enum.each(list, fn {pid, reductions, qlen, current} ->
      assert is_pid(pid)
      assert is_integer(reductions)
      assert is_integer(qlen)
      _ = current
    end)
  end
end
