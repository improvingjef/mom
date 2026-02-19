defmodule Mom.RunnerTest do
  use ExUnit.Case, async: true

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
      assert_receive {:worker_job, job}, 400
      elem(job, 0)
    end)
  end

  defp assert_eventually_seen(expected, receiver, attempts \\ 20)

  defp assert_eventually_seen(expected, _receiver, 0) do
    flunk("expected to see event types #{inspect(expected)}")
  end

  defp assert_eventually_seen(expected, receiver, attempts) do
    seen = Enum.reduce(1..3, MapSet.new(), fn _idx, acc -> MapSet.put(acc, receiver.()) end)

    if Enum.all?(expected, &MapSet.member?(seen, &1)) do
      :ok
    else
      assert_eventually_seen(expected, receiver, attempts - 1)
    end
  end
end
