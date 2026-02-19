defmodule Mom.Acceptance.RunnerPipelineScript do
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
      send(Keyword.fetch!(opts, :parent), {:worker_job, job})
      :ok
    end
  end

  def run do
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
        worker_opts: [parent: self()],
        max_concurrency: 2
      )

    Process.unlink(pid)
    send(pid, {:mom_log, %{id: "err-acceptance"}})

    seen = collect_types(MapSet.new(), 20)
    Process.exit(pid, :kill)

    result = %{
      saw_error_event: MapSet.member?(seen, :error_event),
      saw_diagnostics_event: MapSet.member?(seen, :diagnostics_event),
      unique_types: seen |> MapSet.to_list() |> Enum.sort()
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp collect_types(seen, 0), do: seen

  defp collect_types(seen, attempts) do
    receive do
      {:worker_job, job} ->
        type = elem(job, 0)
        next = MapSet.put(seen, type)

        if MapSet.member?(next, :error_event) and MapSet.member?(next, :diagnostics_event) do
          next
        else
          collect_types(next, attempts - 1)
        end
    after
      200 ->
        collect_types(seen, attempts - 1)
    end
  end
end

Mom.Acceptance.RunnerPipelineScript.run()
