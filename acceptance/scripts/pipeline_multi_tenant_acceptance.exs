defmodule Mom.Acceptance.PipelineMultiTenantScript do
  alias Mom.Pipeline

  defmodule Worker do
    def perform({:error_event, %{id: id, test_pid: test_pid}}, _opts) do
      send(test_pid, {:started, id, self()})

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
        queue_max_size: 10,
        tenant_queue_max_size: 2,
        worker_module: Worker,
        worker_opts: []
      )

    enqueued_a1 = Pipeline.enqueue(pid, {:error_event, %{id: 1, repo: "acme/repo-a", test_pid: self()}})
    enqueued_a2 = Pipeline.enqueue(pid, {:error_event, %{id: 2, repo: "acme/repo-a", test_pid: self()}})
    enqueued_b1 = Pipeline.enqueue(pid, {:error_event, %{id: 3, repo: "acme/repo-b", test_pid: self()}})
    quota_drop = Pipeline.enqueue(pid, {:error_event, %{id: 4, repo: "acme/repo-a", test_pid: self()}})

    {worker1, worker2, worker3} = release_in_fair_order([])
    stats = await_completed(pid, 3)

    result = %{
      enqueued_a1: normalize(enqueued_a1),
      enqueued_a2: normalize(enqueued_a2),
      enqueued_b1: normalize(enqueued_b1),
      quota_drop: normalize(quota_drop),
      start_order: [worker1, worker2, worker3],
      final_queue_depth: stats.queue_depth,
      final_completed_count: stats.completed_count,
      final_dropped_count: stats.dropped_count
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp release_in_fair_order(acc) do
    if length(acc) == 3 do
      List.to_tuple(Enum.reverse(acc))
    else
      receive do
        {:started, id, worker} ->
          send(worker, :release)
          release_in_fair_order([id | acc])
      after
        2_000 ->
          raise "timed out waiting for worker start"
      end
    end
  end

  defp await_completed(pid, target, retries \\ 50)

  defp await_completed(pid, _target, 0), do: Pipeline.stats(pid)

  defp await_completed(pid, target, retries) do
    stats = Pipeline.stats(pid)

    if stats.completed_count >= target and stats.queue_depth == 0 do
      stats
    else
      Process.sleep(10)
      await_completed(pid, target, retries - 1)
    end
  end

  defp normalize(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&normalize/1)
  end

  defp normalize(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {k, normalize(v)} end)
  end

  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.PipelineMultiTenantScript.run()
