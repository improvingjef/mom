defmodule Mom.PipelineTest do
  use ExUnit.Case, async: true

  alias Mom.Pipeline

  defmodule TestWorker do
    def perform({:error_event, %{id: id, test_pid: test_pid}}, _opts) do
      send(test_pid, {:started, id, self()})

      receive do
        :release -> :ok
      end
    end
  end

  test "enqueues supported incident types" do
    pid = start_supervised!({Pipeline, []})

    assert :ok == Pipeline.enqueue(pid, {:error_event, %{message: "boom"}})
    assert :ok == Pipeline.enqueue(pid, {:diagnostics_event, %{memory: %{}}, [:memory_high]})

    assert %{queue_depth: 2, dropped_count: 0, overflow_policy: :drop_newest} =
             Pipeline.stats(pid)
  end

  test "drop_newest keeps existing queued jobs when full" do
    pid = start_supervised!({Pipeline, queue_max_size: 2, overflow_policy: :drop_newest})

    assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 1}})
    assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 2}})
    assert {:dropped, :newest} == Pipeline.enqueue(pid, {:error_event, %{id: 3}})

    assert {:ok, {:error_event, %{id: 1}}} == Pipeline.dequeue(pid)
    assert {:ok, {:error_event, %{id: 2}}} == Pipeline.dequeue(pid)
    assert :empty == Pipeline.dequeue(pid)
  end

  test "drop_oldest evicts oldest job when full" do
    pid = start_supervised!({Pipeline, queue_max_size: 2, overflow_policy: :drop_oldest})

    assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 1}})
    assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 2}})
    assert {:dropped, :oldest} == Pipeline.enqueue(pid, {:error_event, %{id: 3}})

    assert {:ok, {:error_event, %{id: 2}}} == Pipeline.dequeue(pid)
    assert {:ok, {:error_event, %{id: 3}}} == Pipeline.dequeue(pid)
    assert :empty == Pipeline.dequeue(pid)

    assert %{dropped_count: 1} = Pipeline.stats(pid)
  end

  test "rejects unsupported event payloads" do
    pid = start_supervised!({Pipeline, []})
    assert {:error, :invalid_job} == Pipeline.enqueue(pid, {:unknown, %{}})
  end

  test "dispatches jobs up to max_concurrency" do
    pid =
      start_supervised!(
        {Pipeline,
         dispatch?: true, max_concurrency: 2, worker_module: TestWorker, worker_opts: []}
      )

    assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 1, test_pid: self()}})
    assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 2, test_pid: self()}})
    assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 3, test_pid: self()}})

    assert_receive {:started, 1, worker1}
    assert_receive {:started, 2, worker2}
    refute_receive {:started, 3, _}, 100

    send(worker1, :release)
    assert_receive {:started, 3, worker3}

    send(worker2, :release)
    send(worker3, :release)

    eventually(fn ->
      assert %{queue_depth: 0, active_workers: 0, completed_count: 3} = Pipeline.stats(pid)
    end)
  end

  defp eventually(fun, retries \\ 20)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(fun, retries - 1)
  end
end
