defmodule Mom.PipelineTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mom.Pipeline

  defmodule TestWorker do
    def perform({:error_event, %{id: id, test_pid: test_pid}}, _opts) do
      send(test_pid, {:started, id, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defmodule FailingWorker do
    def perform({:error_event, %{id: id, test_pid: test_pid}}, _opts) do
      send(test_pid, {:started, id, self()})
      Process.sleep(10)
      raise "worker boom"
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

  test "enforces per-tenant queue quotas" do
    pid =
      start_supervised!(
        {Pipeline, queue_max_size: 10, tenant_queue_max_size: 1, overflow_policy: :drop_newest}
      )

    assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 1, repo: "acme/repo-a"}})

    assert {:dropped, :tenant_quota} ==
             Pipeline.enqueue(pid, {:error_event, %{id: 2, repo: "acme/repo-a"}})

    assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 3, repo: "acme/repo-b"}})

    assert {:ok, {:error_event, %{id: 1, repo: "acme/repo-a"}}} == Pipeline.dequeue(pid)
    assert {:ok, {:error_event, %{id: 3, repo: "acme/repo-b"}}} == Pipeline.dequeue(pid)
    assert :empty == Pipeline.dequeue(pid)
    assert %{dropped_count: 1} = Pipeline.stats(pid)
  end

  test "enforces per-tenant queue quotas across active and queued jobs" do
    pid =
      start_supervised!(
        {Pipeline,
         dispatch?: true,
         max_concurrency: 1,
         tenant_queue_max_size: 2,
         queue_max_size: 10,
         worker_module: TestWorker,
         worker_opts: []}
      )

    assert :ok ==
             Pipeline.enqueue(
               pid,
               {:error_event, %{id: 21, repo: "acme/repo-a", test_pid: self()}}
             )

    assert_receive {:started, 21, worker}

    assert :ok ==
             Pipeline.enqueue(
               pid,
               {:error_event, %{id: 22, repo: "acme/repo-a", test_pid: self()}}
             )

    assert {:dropped, :tenant_quota} ==
             Pipeline.enqueue(
               pid,
               {:error_event, %{id: 23, repo: "acme/repo-a", test_pid: self()}}
             )

    send(worker, :release)
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

  test "dispatches queued jobs fairly across tenants" do
    pid =
      start_supervised!(
        {Pipeline,
         dispatch?: true, max_concurrency: 1, worker_module: TestWorker, worker_opts: []}
      )

    assert :ok ==
             Pipeline.enqueue(
               pid,
               {:error_event, %{id: 1, repo: "acme/repo-a", test_pid: self()}}
             )

    assert :ok ==
             Pipeline.enqueue(
               pid,
               {:error_event, %{id: 2, repo: "acme/repo-a", test_pid: self()}}
             )

    assert :ok ==
             Pipeline.enqueue(
               pid,
               {:error_event, %{id: 3, repo: "acme/repo-b", test_pid: self()}}
             )

    assert_receive {:started, 1, worker1}
    send(worker1, :release)

    assert_receive {:started, 3, worker2}
    send(worker2, :release)

    assert_receive {:started, 2, worker3}
    send(worker3, :release)

    eventually(fn ->
      assert %{queue_depth: 0, active_workers: 0, completed_count: 3} = Pipeline.stats(pid)
    end)
  end

  test "drops duplicate in-flight jobs and allows re-enqueue after completion" do
    pid =
      start_supervised!(
        {Pipeline,
         dispatch?: true, max_concurrency: 1, worker_module: TestWorker, worker_opts: []}
      )

    job = {:error_event, %{id: 11, test_pid: self()}}

    assert :ok == Pipeline.enqueue(pid, job)
    assert_receive {:started, 11, worker}

    assert {:dropped, :inflight} == Pipeline.enqueue(pid, job)
    assert %{queue_depth: 0, dropped_count: 1, active_workers: 1} = Pipeline.stats(pid)

    send(worker, :release)

    eventually(fn ->
      assert %{completed_count: 1, active_workers: 0} = Pipeline.stats(pid)
    end)

    assert :ok == Pipeline.enqueue(pid, job)
    assert_receive {:started, 11, worker2}
    send(worker2, :release)
  end

  test "isolates in-flight dedupe signatures per tenant" do
    pid =
      start_supervised!(
        {Pipeline,
         dispatch?: true, max_concurrency: 1, worker_module: TestWorker, worker_opts: []}
      )

    job_a = {:error_event, %{id: 44, repo: "acme/repo-a", test_pid: self()}}
    job_b = {:error_event, %{id: 44, repo: "acme/repo-b", test_pid: self()}}

    assert :ok == Pipeline.enqueue(pid, job_a)
    assert_receive {:started, 44, worker_a}

    assert :ok == Pipeline.enqueue(pid, job_b)
    assert %{queue_depth: 1, dropped_count: 0} = Pipeline.stats(pid)

    send(worker_a, :release)
    assert_receive {:started, 44, worker_b}
    send(worker_b, :release)
  end

  test "cleans up in-flight signature when worker fails" do
    pid =
      start_supervised!(
        {Pipeline,
         dispatch?: true, max_concurrency: 1, worker_module: FailingWorker, worker_opts: []}
      )

    job = {:error_event, %{id: 12, test_pid: self()}}

    assert :ok == Pipeline.enqueue(pid, job)
    assert_receive {:started, 12, _worker}

    eventually(fn ->
      assert %{failed_count: 1, active_workers: 0} = Pipeline.stats(pid)
    end)

    assert :ok == Pipeline.enqueue(pid, job)
    assert_receive {:started, 12, _worker2}
  end

  test "emits telemetry for enqueue, dispatch, completion, drop, and failure" do
    handler_id = "pipeline-test-#{System.unique_integer([:positive])}"
    test_pid = self()

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
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    success_pid =
      start_supervised!(
        {Pipeline,
         dispatch?: true, max_concurrency: 1, worker_module: TestWorker, worker_opts: []},
        id: "pipeline-success-#{System.unique_integer([:positive])}"
      )

    assert :ok == Pipeline.enqueue(success_pid, {:error_event, %{id: 1, test_pid: self()}})
    assert_receive {:started, 1, worker1}
    send(worker1, :release)

    assert_receive {:telemetry_event, [:mom, :pipeline, :enqueued], _, %{job_type: :error_event}}
    assert_receive {:telemetry_event, [:mom, :pipeline, :started], _, %{job_type: :error_event}}

    assert_receive {:telemetry_event, [:mom, :pipeline, :completed], measurements,
                    %{job_type: :error_event}}

    assert is_integer(measurements.duration)
    assert measurements.duration >= 0

    drop_pid =
      start_supervised!(
        {Pipeline, queue_max_size: 1, overflow_policy: :drop_newest},
        id: "pipeline-drop-#{System.unique_integer([:positive])}"
      )

    assert :ok == Pipeline.enqueue(drop_pid, {:error_event, %{id: 2}})
    assert {:dropped, :newest} == Pipeline.enqueue(drop_pid, {:error_event, %{id: 3}})
    assert_receive {:telemetry_event, [:mom, :pipeline, :dropped], _, %{drop_reason: :newest}}

    fail_pid =
      start_supervised!(
        {Pipeline,
         dispatch?: true, max_concurrency: 1, worker_module: FailingWorker, worker_opts: []},
        id: "pipeline-fail-#{System.unique_integer([:positive])}"
      )

    assert :ok == Pipeline.enqueue(fail_pid, {:error_event, %{id: 4, test_pid: self()}})
    assert_receive {:started, 4, _worker}

    {failed_measurements, reason} = await_failed_event()

    assert is_integer(failed_measurements.duration)
    assert failed_measurements.duration >= 0
    assert reason != nil
  end

  test "logs queue and worker lifecycle fields" do
    pid =
      start_supervised!(
        {Pipeline,
         dispatch?: true, max_concurrency: 1, worker_module: TestWorker, worker_opts: []}
      )

    log =
      capture_log(fn ->
        assert :ok == Pipeline.enqueue(pid, {:error_event, %{id: 7, test_pid: self()}})
        assert_receive {:started, 7, worker}
        send(worker, :release)

        eventually(fn ->
          assert %{completed_count: 1} = Pipeline.stats(pid)
        end)
      end)

    assert log =~ "mom: pipeline enqueued"
    assert log =~ "job_type=:error_event"
    assert log =~ "mom: pipeline started"
    assert log =~ "queue_depth="
    assert log =~ "active_workers="
    assert log =~ "mom: pipeline completed"
  end

  test "persists queued jobs and replays them after restart when durable_queue_path is configured" do
    durable_queue_path = durable_queue_fixture_path()

    pid1 =
      start_supervised!(
        {Pipeline, queue_max_size: 5, durable_queue_path: durable_queue_path},
        id: "pipeline-durable-1-#{System.unique_integer([:positive])}"
      )

    assert :ok == Pipeline.enqueue(pid1, {:error_event, %{id: 101}})
    assert :ok == Pipeline.enqueue(pid1, {:diagnostics_event, %{run_queue: 3}, [:memory_high]})

    assert File.exists?(durable_queue_path)
    assert %{queue_depth: 2} = Pipeline.stats(pid1)

    Process.exit(pid1, :shutdown)
    assert_down(pid1)

    pid2 =
      start_supervised!(
        {Pipeline, queue_max_size: 5, durable_queue_path: durable_queue_path},
        id: "pipeline-durable-2-#{System.unique_integer([:positive])}"
      )

    assert {:ok, {:error_event, %{id: 101}}} == Pipeline.dequeue(pid2)
    assert {:ok, {:diagnostics_event, %{run_queue: 3}, [:memory_high]}} == Pipeline.dequeue(pid2)
    assert :empty == Pipeline.dequeue(pid2)
  end

  test "updates persisted queue snapshot when jobs are drained" do
    durable_queue_path = durable_queue_fixture_path()

    pid1 =
      start_supervised!(
        {Pipeline, queue_max_size: 5, durable_queue_path: durable_queue_path},
        id: "pipeline-durable-drain-1-#{System.unique_integer([:positive])}"
      )

    assert :ok == Pipeline.enqueue(pid1, {:error_event, %{id: 102}})
    assert {:ok, {:error_event, %{id: 102}}} == Pipeline.dequeue(pid1)

    Process.exit(pid1, :shutdown)
    assert_down(pid1)

    pid2 =
      start_supervised!(
        {Pipeline, queue_max_size: 5, durable_queue_path: durable_queue_path},
        id: "pipeline-durable-drain-2-#{System.unique_integer([:positive])}"
      )

    assert :empty == Pipeline.dequeue(pid2)
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

  defp await_failed_event(timeout_ms \\ 1_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_failed_event(deadline_ms)
  end

  defp do_await_failed_event(deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      raise ExUnit.AssertionError, message: "missing telemetry failed pipeline event"
    end

    receive do
      {:telemetry_event, [:mom, :pipeline, :failed], measurements,
       %{job_type: :error_event, reason: reason}} ->
        {measurements, reason}

      _other ->
        do_await_failed_event(deadline_ms)
    after
      remaining_ms ->
        raise ExUnit.AssertionError, message: "missing telemetry failed pipeline event"
    end
  end

  defp durable_queue_fixture_path do
    base = Path.join(System.tmp_dir!(), "mom-pipeline-durable-tests")
    File.mkdir_p!(base)
    path = Path.join(base, "queue-#{System.unique_integer([:positive])}.bin")
    File.rm_rf(path)
    path
  end

  defp assert_down(pid, timeout_ms \\ 1_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      timeout_ms ->
        raise ExUnit.AssertionError, message: "process #{inspect(pid)} did not terminate"
    end
  end
end
