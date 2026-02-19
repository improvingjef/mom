defmodule Mom.Acceptance.PipelineScript do
  alias Mom.Pipeline

  def run do
    {:ok, pid} = Pipeline.start_link(queue_max_size: 2, overflow_policy: :drop_oldest)

    first = Pipeline.enqueue(pid, {:error_event, %{id: 1}})
    second = Pipeline.enqueue(pid, {:diagnostics_event, %{run_queue: 1}, []})
    overflow = Pipeline.enqueue(pid, {:error_event, %{id: 3}})

    {:ok, kept_first} = Pipeline.dequeue(pid)
    {:ok, kept_second} = Pipeline.dequeue(pid)
    stats = Pipeline.stats(pid)

    result = %{
      first: normalize(first),
      second: normalize(second),
      overflow: normalize(overflow),
      kept_first: normalize(kept_first),
      kept_second: normalize(kept_second),
      queue_depth: stats.queue_depth,
      dropped_count: stats.dropped_count
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
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

Mom.Acceptance.PipelineScript.run()
