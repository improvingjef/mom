defmodule Mom.DiagnosticsTest do
  use ExUnit.Case

  alias Mom.{Config, Diagnostics}

  test "evaluate_vm_event triggers on memory threshold exceeded" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        mode: :inproc,
        triage_on_diagnostics: true,
        diag_mem_high_bytes: 0,
        diag_cooldown_ms: 0
      )

    event = %{
      event: [:vm, :memory],
      measurements: %{total: 500_000_000},
      node: :test@localhost,
      at: System.system_time(:millisecond)
    }

    last = System.monotonic_time(:millisecond) - 10_000
    {issues, trigger?, _now} = Diagnostics.evaluate_vm_event(event, config, last)
    assert issues != []
    assert trigger? == true
  end

  test "evaluate_vm_event triggers on run queue threshold exceeded" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        mode: :inproc,
        triage_on_diagnostics: true,
        diag_run_queue_mult: 1,
        diag_cooldown_ms: 0
      )

    event = %{
      event: [:vm, :total_run_queue_lengths],
      measurements: %{total: 100, cpu: 2},
      node: :test@localhost,
      at: System.system_time(:millisecond)
    }

    last = System.monotonic_time(:millisecond) - 10_000
    {issues, trigger?, _now} = Diagnostics.evaluate_vm_event(event, config, last)
    assert [{:run_queue_high, 100, 2, 1}] = issues
    assert trigger? == true
  end

  test "evaluate_vm_event respects cooldown" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        mode: :inproc,
        triage_on_diagnostics: true,
        diag_mem_high_bytes: 0,
        diag_cooldown_ms: 10_000
      )

    event = %{
      event: [:vm, :memory],
      measurements: %{total: 500_000_000},
      node: :test@localhost,
      at: System.system_time(:millisecond)
    }

    now = System.monotonic_time(:millisecond)
    {_issues, trigger?, _now} = Diagnostics.evaluate_vm_event(event, config, now)
    assert trigger? == false
  end

  test "evaluate_system_monitor always reports issues" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        mode: :inproc,
        triage_on_diagnostics: true,
        diag_cooldown_ms: 0
      )

    event = %{type: :long_gc, info: %{heap_size: 1_000_000}, pid: self()}
    last = System.monotonic_time(:millisecond) - 10_000
    {issues, trigger?, _now} = Diagnostics.evaluate_system_monitor(event, config, last)
    assert [{:long_gc, _}] = issues
    assert trigger? == true
  end

  test "evaluate_query detects slow queries" do
    {:ok, config} =
      Config.from_opts(repo: "/tmp/repo", mode: :inproc)

    # 2 seconds in native time
    slow_time = System.convert_time_unit(2000, :millisecond, :native)

    event = %{
      event: [:latte, :repo, :query],
      measurements: %{total_time: slow_time},
      metadata: %{source: "users"},
      node: :test@localhost,
      at: System.system_time(:millisecond)
    }

    {issues, trigger?, _now} = Diagnostics.evaluate_query(event, config, 0)
    assert [{:slow_query, _, "users"}] = issues
    assert trigger? == true
  end

  test "evaluate_query ignores fast queries" do
    {:ok, config} =
      Config.from_opts(repo: "/tmp/repo", mode: :inproc)

    fast_time = System.convert_time_unit(5, :millisecond, :native)

    event = %{
      event: [:latte, :repo, :query],
      measurements: %{total_time: fast_time},
      metadata: %{source: "users"},
      node: :test@localhost,
      at: System.system_time(:millisecond)
    }

    {issues, trigger?, _now} = Diagnostics.evaluate_query(event, config, 0)
    assert issues == []
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

  test "local_report returns expected keys" do
    report = Diagnostics.local_report()
    assert is_list(report.memory)
    assert is_integer(report.run_queue)
    assert is_integer(report.process_count)
    assert is_integer(report.schedulers)
  end
end
