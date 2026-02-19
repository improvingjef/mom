defmodule Mom.Acceptance.RunnerBurstScript do
  alias Mom.{Config, Runner}
  require Logger

  defmodule FakeBeam do
    def ensure_node_started(_cookie), do: :ok
    def attach_logger(_config, _pid), do: :ok
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
      parent = Keyword.fetch!(opts, :parent)
      send(parent, {:worker_job, :error_event, id})

      if id == Keyword.fetch!(opts, :fail_id) do
        raise "intentional burst failure"
      end

      :ok
    end

    def perform({:diagnostics_event, report, _issues}, opts) do
      send(Keyword.fetch!(opts, :parent), {:worker_job, :diagnostics_event, report.seq})
      :ok
    end
  end

  def run do
    previous_level = Logger.level()

    try do
      Logger.configure(level: :emergency)

      {:ok, config} =
        Config.from_opts(
          repo: "/tmp/repo",
          mode: :inproc,
          poll_interval_ms: 100,
          triage_on_diagnostics: true,
          diag_cooldown_ms: 0
        )

      fail_id = "err-fail"
      error_ids = [fail_id | Enum.map(1..14, &"err-#{&1}")]

      {:ok, pid} =
        Runner.start(config,
          beam_module: FakeBeam,
          diagnostics_module: BurstDiagnostics,
          worker_module: BurstCaptureWorker,
          worker_opts: [parent: self(), fail_id: fail_id],
          max_concurrency: 4,
          queue_max_size: 80
        )

      Process.unlink(pid)

      Enum.each(error_ids, fn id ->
        send(pid, {:mom_log, %{id: id}})
      end)

      {error_seen, diagnostics_seen} = await_burst_results(MapSet.new(), 0, 120)

      alive_after_burst = Process.alive?(pid)

      Process.exit(pid, :kill)

      result = %{
        mixed_types_seen: diagnostics_seen > 0 and MapSet.size(error_seen) > 0,
        all_error_events_processed: MapSet.subset?(MapSet.new(error_ids), error_seen),
        diagnostics_processed: diagnostics_seen,
        runner_alive_after_burst: alive_after_burst
      }

      IO.puts("RESULT_JSON:" <> Jason.encode!(result))
      :ok
    after
      Logger.configure(level: previous_level)
    end
  end

  defp await_burst_results(error_seen, diagnostics_seen, 0), do: {error_seen, diagnostics_seen}

  defp await_burst_results(error_seen, diagnostics_seen, attempts) do
    receive do
      {:worker_job, :error_event, id} ->
        await_burst_results(MapSet.put(error_seen, id), diagnostics_seen, attempts - 1)

      {:worker_job, :diagnostics_event, _seq} ->
        await_burst_results(error_seen, diagnostics_seen + 1, attempts - 1)
    after
      50 ->
        await_burst_results(error_seen, diagnostics_seen, attempts - 1)
    end
  end
end

Mom.Acceptance.RunnerBurstScript.run()
