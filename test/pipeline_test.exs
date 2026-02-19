defmodule Mom.PipelineTest do
  use ExUnit.Case, async: true

  alias Mom.Pipeline

  test "enqueues supported incident types" do
    pid = start_supervised!({Pipeline, []})

    assert :ok == Pipeline.enqueue(pid, {:error_event, %{message: "boom"}})
    assert :ok == Pipeline.enqueue(pid, {:diagnostics_event, %{memory: %{}}, [:memory_high]})

    assert %{queue_depth: 2, dropped_count: 0, overflow_policy: :drop_newest} = Pipeline.stats(pid)
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
end
