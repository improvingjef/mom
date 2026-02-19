defmodule Mom.Acceptance.PipelineDispatchScript do
  alias Mom.Pipeline

  defmodule TestWorker do
    def perform({:error_event, %{id: id, parent: parent}}, _opts) do
      send(parent, {:started, id, self()})

      receive do
        :release -> :ok
      end
    end
  end

  def run do
    {:ok, pid} =
      Pipeline.start_link(
        dispatch?: true,
        max_concurrency: 2,
        worker_module: TestWorker,
        worker_opts: []
      )

    parent = self()
    :ok = Pipeline.enqueue(pid, {:error_event, %{id: 1, parent: parent}})
    :ok = Pipeline.enqueue(pid, {:error_event, %{id: 2, parent: parent}})
    :ok = Pipeline.enqueue(pid, {:error_event, %{id: 3, parent: parent}})

    started = [await_started(), await_started()]
    third_started_early? = third_started_within?(100)

    [{_id1, worker1}, {_id2, worker2}] = started
    send(worker1, :release)
    {third_id, worker3} = await_started()

    send(worker2, :release)
    send(worker3, :release)

    stats = await_stats(pid)

    result = %{
      started_initial_count: length(started),
      third_started_early: third_started_early?,
      third_started_after_release_id: third_id,
      active_workers: stats.active_workers,
      completed_count: stats.completed_count,
      queue_depth: stats.queue_depth
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp await_started(timeout \\ 1_000) do
    receive do
      {:started, id, worker} -> {id, worker}
    after
      timeout ->
        raise "timed out waiting for worker start"
    end
  end

  defp third_started_within?(timeout) do
    receive do
      {:started, _id, _worker} -> true
    after
      timeout -> false
    end
  end

  defp await_stats(pid, retries \\ 50)

  defp await_stats(pid, 0), do: Pipeline.stats(pid)

  defp await_stats(pid, retries) do
    stats = Pipeline.stats(pid)

    if stats.active_workers == 0 and stats.queue_depth == 0 and stats.completed_count == 3 do
      stats
    else
      Process.sleep(10)
      await_stats(pid, retries - 1)
    end
  end
end

Mom.Acceptance.PipelineDispatchScript.run()
