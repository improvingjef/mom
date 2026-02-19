defmodule Mom.Acceptance.PipelineTelemetryScript do
  alias Mom.Pipeline

  defmodule OkWorker do
    def perform(_job, _opts) do
      Process.sleep(10)
      :ok
    end
  end

  defmodule BoomWorker do
    def perform(_job, _opts) do
      Process.sleep(10)
      raise("boom")
    end
  end

  def run do
    parent = self()
    handler_id = "pipeline-acceptance-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:mom, :pipeline, :enqueued],
          [:mom, :pipeline, :dropped],
          [:mom, :pipeline, :started],
          [:mom, :pipeline, :completed],
          [:mom, :pipeline, :failed]
        ],
        fn event, _measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, metadata})
        end,
        nil
      )

    try do
      {:ok, ok_pid} =
        Pipeline.start_link(
          dispatch?: true,
          max_concurrency: 1,
          worker_module: OkWorker,
          worker_opts: []
        )

      :ok = Pipeline.enqueue(ok_pid, {:error_event, %{id: 1}})
      wait_for(fn -> Pipeline.stats(ok_pid).completed_count == 1 end)

      {:ok, drop_pid} = Pipeline.start_link(queue_max_size: 1, overflow_policy: :drop_newest)
      :ok = Pipeline.enqueue(drop_pid, {:error_event, %{id: 2}})
      {:dropped, :newest} = Pipeline.enqueue(drop_pid, {:error_event, %{id: 3}})

      {:ok, fail_pid} =
        Pipeline.start_link(
          dispatch?: true,
          max_concurrency: 1,
          worker_module: BoomWorker,
          worker_opts: []
        )

      :ok = Pipeline.enqueue(fail_pid, {:error_event, %{id: 4}})
      wait_for(fn -> Pipeline.stats(fail_pid).failed_count == 1 end)

      events = collect_events([])

      result = %{
        saw_enqueued: saw_event?(events, :enqueued),
        saw_dropped: saw_event?(events, :dropped),
        saw_started: saw_event?(events, :started),
        saw_completed: saw_event?(events, :completed),
        saw_failed: saw_event?(events, :failed),
        event_has_fields:
          Enum.all?(events, fn {_name, metadata} ->
            Map.has_key?(metadata, :queue_depth) and Map.has_key?(metadata, :active_workers)
          end),
        failed_count: Pipeline.stats(fail_pid).failed_count
      }

      IO.puts("RESULT_JSON:" <> Jason.encode!(result))
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_events(acc) do
    receive do
      {:telemetry_event, event, metadata} ->
        name = List.last(event)
        collect_events([{name, metadata} | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defp saw_event?(events, name) do
    Enum.any?(events, fn {event_name, _metadata} -> event_name == name end)
  end

  defp wait_for(fun, retries \\ 500)

  defp wait_for(fun, 0) do
    if fun.(), do: :ok, else: raise("timed out waiting for condition")
  end

  defp wait_for(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_for(fun, retries - 1)
    end
  end
end

Mom.Acceptance.PipelineTelemetryScript.run()
