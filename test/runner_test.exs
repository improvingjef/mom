defmodule Mom.RunnerTest do
  use ExUnit.Case, async: false

  alias Mom.{Config, Runner}

  defmodule FakeBeam do
    def ensure_node_started(_cookie), do: :ok
    def attach_logger(_config, _pid), do: :ok
  end

  defmodule FakeDiagnostics do
    def poll(_config, _last_triage_at) do
      {%{source: :diagnostics}, [:cpu_high], true, System.monotonic_time(:millisecond)}
    end
  end

  defmodule CaptureWorker do
    def perform(job, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:worker_job, job})
      :ok
    end
  end

  defmodule BurstDiagnostics do
    def poll(_config, last_triage_at) do
      seq = last_triage_at + 1

      if seq <= 2 do
        {%{source: :diagnostics, seq: seq}, [:cpu_high], true, seq}
      else
        {%{source: :diagnostics, seq: seq}, [], false, last_triage_at}
      end
    end
  end

  defmodule BurstCaptureWorker do
    def perform({:error_event, %{id: id}}, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:worker_job, :error_event, id})

      if id == Keyword.fetch!(opts, :fail_id) do
        raise "intentional burst failure"
      end

      :ok
    end

    def perform({:diagnostics_event, report, _issues}, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:worker_job, :diagnostics_event, report.seq})
      :ok
    end
  end

  test "routes log and diagnostics events through pipeline workers" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        mode: :inproc,
        poll_interval_ms: 20,
        triage_on_diagnostics: true,
        diag_cooldown_ms: 0
      )

    {:ok, pid} =
      Runner.start(config,
        beam_module: FakeBeam,
        diagnostics_module: FakeDiagnostics,
        worker_module: CaptureWorker,
        worker_opts: [test_pid: self()],
        max_concurrency: 2
      )

    Process.unlink(pid)
    on_exit(fn -> Process.exit(pid, :kill) end)

    send(pid, {:mom_log, %{id: "err-1"}})

    assert_eventually_seen([:error_event, :diagnostics_event], fn ->
      receive do
        {:worker_job, job} -> {:ok, elem(job, 0)}
      after
        400 -> :none
      end
    end)
  end

  test "handles burst mixed events without runner deadlock after a worker failure" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        mode: :inproc,
        poll_interval_ms: 100,
        triage_on_diagnostics: true,
        diag_cooldown_ms: 0
      )

    fail_id = "err-fail"

    {:ok, pid} =
      Runner.start(config,
        beam_module: FakeBeam,
        diagnostics_module: BurstDiagnostics,
        worker_module: BurstCaptureWorker,
        worker_opts: [test_pid: self(), fail_id: fail_id],
        max_concurrency: 4,
        queue_max_size: 80
      )

    Process.unlink(pid)
    on_exit(fn -> Process.exit(pid, :kill) end)

    error_ids = [fail_id | Enum.map(1..14, &"err-#{&1}")]

    Enum.each(error_ids, fn id ->
      send(pid, {:mom_log, %{id: id}})
    end)

    {error_seen, diagnostics_seen} =
      collect_burst_results(MapSet.new(), 0, MapSet.new(error_ids), 10_000)

    assert MapSet.subset?(MapSet.new(error_ids), error_seen)
    assert diagnostics_seen >= 1
    assert Process.alive?(pid)
  end

  defp assert_eventually_seen(expected, receiver, attempts \\ 20)

  defp assert_eventually_seen(expected, _receiver, 0) do
    flunk("expected to see event types #{inspect(expected)}")
  end

  defp assert_eventually_seen(expected, receiver, attempts) do
    seen =
      Enum.reduce(1..3, MapSet.new(), fn _idx, acc ->
        case receiver.() do
          {:ok, type} -> MapSet.put(acc, type)
          :none -> acc
        end
      end)

    if Enum.all?(expected, &MapSet.member?(seen, &1)) do
      :ok
    else
      Process.sleep(20)
      assert_eventually_seen(expected, receiver, attempts - 1)
    end
  end

  defp collect_burst_results(error_seen, diagnostics_seen, expected_error_ids, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_burst_results(error_seen, diagnostics_seen, expected_error_ids, deadline_ms)
  end

  defp do_collect_burst_results(error_seen, diagnostics_seen, expected_error_ids, deadline_ms) do
    cond do
      MapSet.subset?(expected_error_ids, error_seen) and diagnostics_seen >= 1 ->
        {error_seen, diagnostics_seen}

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk(
          "timed out waiting for burst results: missing_error_ids=#{inspect(MapSet.difference(expected_error_ids, error_seen))} diagnostics_seen=#{diagnostics_seen}"
        )

      true ->
        do_collect_burst_results_receive(
          error_seen,
          diagnostics_seen,
          expected_error_ids,
          deadline_ms
        )
    end
  end

  defp do_collect_burst_results_receive(
         error_seen,
         diagnostics_seen,
         expected_error_ids,
         deadline_ms
       ) do
    receive do
      {:worker_job, :error_event, id} ->
        do_collect_burst_results(
          MapSet.put(error_seen, id),
          diagnostics_seen,
          expected_error_ids,
          deadline_ms
        )

      {:worker_job, :diagnostics_event, _seq} ->
        do_collect_burst_results(
          error_seen,
          diagnostics_seen + 1,
          expected_error_ids,
          deadline_ms
        )

      _other ->
        do_collect_burst_results(error_seen, diagnostics_seen, expected_error_ids, deadline_ms)
    after
      25 ->
        do_collect_burst_results(error_seen, diagnostics_seen, expected_error_ids, deadline_ms)
    end
  end
end
