defmodule Mom.Acceptance.PipelineTimeoutScript do
  alias Mom.{Config, Pipeline, Workers.EngineTriage}

  defmodule TimeoutEngine do
    def handle_log(%{id: 1, parent: parent}, _config) do
      send(parent, {:engine_started, :slow, self()})

      receive do
        :never -> :ok
      end
    end

    def handle_log(%{id: 2, parent: parent}, _config) do
      send(parent, {:engine_started, :fast, self()})
      :ok
    end

    def handle_diagnostics(_report, _issues, _config), do: :ok
  end

  def run do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo", mode: :inproc)

    {:ok, pid} =
      Pipeline.start_link(
        dispatch?: true,
        max_concurrency: 1,
        worker_module: EngineTriage,
        worker_opts: [config: config, engine_module: TimeoutEngine, job_timeout_ms: 40]
      )

    parent = self()
    :ok = Pipeline.enqueue(pid, {:error_event, %{id: 1, parent: parent}})
    :ok = Pipeline.enqueue(pid, {:error_event, %{id: 2, parent: parent}})

    slow_started = await_start(:slow)
    fast_started_early = started_within?(:fast, 20)
    fast_started = await_start(:fast)
    stats = await_stats(pid)

    result = %{
      slow_started: slow_started,
      fast_started_early: fast_started_early,
      fast_started: fast_started,
      active_workers: stats.active_workers,
      completed_count: stats.completed_count,
      queue_depth: stats.queue_depth
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp await_start(type, timeout \\ 1_000) do
    receive do
      {:engine_started, ^type, _engine_pid} -> true
    after
      timeout -> false
    end
  end

  defp started_within?(type, timeout) do
    receive do
      {:engine_started, ^type, _engine_pid} -> true
    after
      timeout -> false
    end
  end

  defp await_stats(pid, retries \\ 80)

  defp await_stats(pid, 0), do: Pipeline.stats(pid)

  defp await_stats(pid, retries) do
    stats = Pipeline.stats(pid)

    if stats.active_workers == 0 and stats.queue_depth == 0 and stats.completed_count == 2 do
      stats
    else
      Process.sleep(10)
      await_stats(pid, retries - 1)
    end
  end
end

Mom.Acceptance.PipelineTimeoutScript.run()
