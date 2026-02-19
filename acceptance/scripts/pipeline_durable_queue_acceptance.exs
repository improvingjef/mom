defmodule Mom.Acceptance.PipelineDurableQueueScript do
  alias Mom.Pipeline

  def run do
    durable_queue_path =
      Path.join(
        System.tmp_dir!(),
        "mom-acceptance-durable-queue-#{System.unique_integer([:positive])}.bin"
      )

    File.rm_rf(durable_queue_path)

    {:ok, first_pid} =
      Pipeline.start_link(
        queue_max_size: 8,
        overflow_policy: :drop_newest,
        durable_queue_path: durable_queue_path
      )

    first = Pipeline.enqueue(first_pid, {:error_event, %{id: 501}})
    second = Pipeline.enqueue(first_pid, {:diagnostics_event, %{run_queue: 2}, [:memory_high]})
    stop_and_wait(first_pid)

    {:ok, replay_pid} =
      Pipeline.start_link(
        queue_max_size: 8,
        overflow_policy: :drop_newest,
        durable_queue_path: durable_queue_path
      )

    replay_depth = Pipeline.stats(replay_pid).queue_depth
    replay_first = Pipeline.dequeue(replay_pid)
    replay_second = Pipeline.dequeue(replay_pid)
    replay_empty = Pipeline.dequeue(replay_pid)
    stop_and_wait(replay_pid)

    {:ok, drained_pid} =
      Pipeline.start_link(
        queue_max_size: 8,
        overflow_policy: :drop_newest,
        durable_queue_path: durable_queue_path
      )

    drained_after_restart = Pipeline.dequeue(drained_pid)

    result = %{
      durable_queue_path_exists: File.exists?(durable_queue_path),
      first: normalize(first),
      second: normalize(second),
      replay_depth: replay_depth,
      replay_first: normalize(replay_first),
      replay_second: normalize(replay_second),
      replay_empty: normalize(replay_empty),
      drained_after_restart: normalize(drained_after_restart)
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal, 1_000)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> raise "pipeline did not stop in time"
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

Mom.Acceptance.PipelineDurableQueueScript.run()
