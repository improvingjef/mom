defmodule Mom.Acceptance.PipelineInflightScript do
  alias Mom.Pipeline

  defmodule HoldWorker do
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
        max_concurrency: 1,
        worker_module: HoldWorker,
        worker_opts: []
      )

    parent = self()
    job = {:error_event, %{id: 41, parent: parent}}

    first = Pipeline.enqueue(pid, job)
    {started_id, worker} = await_started()
    duplicate = Pipeline.enqueue(pid, job)
    before_release = Pipeline.stats(pid)

    send(worker, :release)

    after_release =
      await_stats(pid, fn stats ->
        stats.active_workers == 0 and stats.completed_count == 1
      end)

    after_completion = Pipeline.enqueue(pid, job)
    {restart_id, worker2} = await_started()
    send(worker2, :release)

    final =
      await_stats(pid, fn stats ->
        stats.active_workers == 0 and stats.completed_count == 2
      end)

    result = %{
      first: normalize_result(first),
      started_id: started_id,
      duplicate: normalize_result(duplicate),
      dropped_before_release: before_release.dropped_count,
      queue_depth_before_release: before_release.queue_depth,
      active_before_release: before_release.active_workers,
      after_release_completed: after_release.completed_count,
      after_completion: normalize_result(after_completion),
      restart_id: restart_id,
      final_completed: final.completed_count,
      final_failed: final.failed_count
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp await_started(timeout \\ 1_000) do
    receive do
      {:started, id, worker} -> {id, worker}
    after
      timeout -> raise "timed out waiting for worker start"
    end
  end

  defp await_stats(pid, done?, retries \\ 80)

  defp await_stats(pid, _done?, 0), do: Pipeline.stats(pid)

  defp await_stats(pid, done?, retries) do
    stats = Pipeline.stats(pid)

    if done?.(stats) do
      stats
    else
      Process.sleep(10)
      await_stats(pid, done?, retries - 1)
    end
  end

  defp normalize_result(:ok), do: "ok"
  defp normalize_result({:dropped, reason}), do: ["dropped", Atom.to_string(reason)]
end

Mom.Acceptance.PipelineInflightScript.run()
