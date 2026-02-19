defmodule Mom.Pipeline do
  @moduledoc false

  use GenServer

  alias Mom.WorkerSupervisor
  require Logger

  @type overflow_policy :: :drop_newest | :drop_oldest
  @type supported_job ::
          {:error_event, map()}
          | {:diagnostics_event, map(), list()}

  @type enqueue_result :: :ok | {:dropped, :newest | :oldest} | {:error, :invalid_job}

  @default_queue_max_size 200
  @default_overflow_policy :drop_newest
  @default_max_concurrency 4

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec enqueue(pid() | atom(), supported_job()) :: enqueue_result()
  def enqueue(server, job) do
    GenServer.call(server, {:enqueue, job})
  end

  @spec dequeue(pid() | atom()) :: {:ok, supported_job()} | :empty
  def dequeue(server) do
    GenServer.call(server, :dequeue)
  end

  @spec stats(pid() | atom()) :: %{
          queue_depth: non_neg_integer(),
          active_workers: non_neg_integer(),
          completed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          dropped_count: non_neg_integer(),
          queue_max_size: pos_integer(),
          overflow_policy: overflow_policy(),
          max_concurrency: non_neg_integer()
        }
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    queue_max_size =
      opts
      |> Keyword.get(:queue_max_size, @default_queue_max_size)
      |> normalize_queue_max_size()

    overflow_policy =
      opts
      |> Keyword.get(:overflow_policy, @default_overflow_policy)
      |> normalize_overflow_policy()

    max_concurrency =
      opts
      |> Keyword.get(:max_concurrency, @default_max_concurrency)
      |> normalize_max_concurrency()

    dispatch? = Keyword.get(opts, :dispatch?, false)
    worker_module = Keyword.get(opts, :worker_module)
    worker_opts = Keyword.get(opts, :worker_opts, [])
    worker_supervisor = maybe_start_worker_supervisor(opts, dispatch?)

    {:ok,
     %{
       queue: :queue.new(),
       queue_depth: 0,
       queue_max_size: queue_max_size,
       overflow_policy: overflow_policy,
       dropped_count: 0,
       dispatch?: dispatch?,
       worker_module: worker_module,
       worker_opts: worker_opts,
       worker_supervisor: worker_supervisor,
       max_concurrency: max_concurrency,
       active_workers: %{},
       completed_count: 0,
       failed_count: 0
     }, {:continue, :dispatch}}
  end

  @impl true
  def handle_call({:enqueue, job}, _from, state) do
    if valid_job?(job) do
      result = enqueue_job(job, state)
      next_state = maybe_state(job, state)
      {:reply, result, dispatch_jobs(next_state)}
    else
      {:reply, {:error, :invalid_job}, state}
    end
  end

  def handle_call(:dequeue, _from, %{queue_depth: 0} = state) do
    {:reply, :empty, state}
  end

  def handle_call(:dequeue, _from, state) do
    {{:value, job}, queue} = :queue.out(state.queue)
    next_state = %{state | queue: queue, queue_depth: state.queue_depth - 1}
    {:reply, {:ok, job}, next_state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       queue_depth: state.queue_depth,
       active_workers: map_size(state.active_workers),
       completed_count: state.completed_count,
       failed_count: state.failed_count,
       dropped_count: state.dropped_count,
       queue_max_size: state.queue_max_size,
       overflow_policy: state.overflow_policy,
       max_concurrency: state.max_concurrency
     }, state}
  end

  @impl true
  def handle_continue(:dispatch, state) do
    {:noreply, dispatch_jobs(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.active_workers, ref) do
      {nil, _active_workers} ->
        {:noreply, state}

      {active_job, active_workers} ->
        now = System.monotonic_time()
        measurements = %{duration: now - active_job.started_at}

        metadata =
          common_metadata(
            active_job.job,
            state.queue_depth,
            map_size(active_workers)
          )

        next_state =
          if completed_reason?(reason) do
            telemetry(:completed, measurements, metadata)
            log_pipeline(:info, "completed", metadata, measurements)
            Map.update!(state, :completed_count, &(&1 + 1))
          else
            failure_metadata = Map.put(metadata, :reason, reason)
            telemetry(:failed, measurements, failure_metadata)
            log_pipeline(:warning, "failed", failure_metadata, measurements)
            Map.update!(state, :failed_count, &(&1 + 1))
          end

        next_state =
          next_state
          |> Map.put(:active_workers, active_workers)
          |> dispatch_jobs()

        {:noreply, next_state}
    end
  end

  defp enqueue_job(_job, %{queue_depth: depth, queue_max_size: max} = _state) when depth < max,
    do: :ok

  defp enqueue_job(_job, %{overflow_policy: :drop_newest}), do: {:dropped, :newest}
  defp enqueue_job(_job, %{overflow_policy: :drop_oldest}), do: {:dropped, :oldest}

  defp maybe_state(job, %{queue_depth: depth, queue_max_size: max} = state) when depth < max do
    next_state = %{state | queue: :queue.in(job, state.queue), queue_depth: depth + 1}
    metadata = common_metadata(job, next_state.queue_depth, map_size(next_state.active_workers))
    telemetry(:enqueued, %{count: 1}, metadata)
    log_pipeline(:debug, "enqueued", metadata)
    next_state
  end

  defp maybe_state(_job, %{overflow_policy: :drop_newest} = state) do
    next_state = %{state | dropped_count: state.dropped_count + 1}
    metadata = %{drop_reason: :newest, queue_depth: state.queue_depth, active_workers: map_size(state.active_workers)}
    telemetry(:dropped, %{count: 1}, metadata)
    log_pipeline(:warning, "dropped", metadata)
    next_state
  end

  defp maybe_state(job, %{overflow_policy: :drop_oldest} = state) do
    {{:value, dropped_job}, queue} = :queue.out(state.queue)

    next_state = %{
      state
      | queue: :queue.in(job, queue),
        dropped_count: state.dropped_count + 1
    }

    metadata =
      common_metadata(job, state.queue_depth, map_size(state.active_workers))
      |> Map.put(:drop_reason, :oldest)
      |> Map.put(:dropped_job_type, job_type(dropped_job))

    telemetry(:dropped, %{count: 1}, metadata)
    log_pipeline(:warning, "dropped", metadata)
    next_state
  end

  defp valid_job?({:error_event, event}) when is_map(event), do: true

  defp valid_job?({:diagnostics_event, report, issues}) when is_map(report) and is_list(issues),
    do: true

  defp valid_job?(_job), do: false

  defp normalize_queue_max_size(size) when is_integer(size) and size > 0, do: size
  defp normalize_queue_max_size(_size), do: @default_queue_max_size

  defp normalize_overflow_policy(:drop_newest), do: :drop_newest
  defp normalize_overflow_policy(:drop_oldest), do: :drop_oldest
  defp normalize_overflow_policy(_policy), do: @default_overflow_policy

  defp normalize_max_concurrency(value) when is_integer(value) and value >= 0, do: value
  defp normalize_max_concurrency(_value), do: @default_max_concurrency

  defp maybe_start_worker_supervisor(opts, true) do
    case Keyword.get(opts, :worker_supervisor) do
      nil ->
        {:ok, pid} = WorkerSupervisor.start_link([])
        pid

      pid_or_name ->
        pid_or_name
    end
  end

  defp maybe_start_worker_supervisor(_opts, false), do: nil

  defp dispatch_jobs(%{dispatch?: false} = state), do: state
  defp dispatch_jobs(%{worker_module: nil} = state), do: state
  defp dispatch_jobs(%{max_concurrency: 0} = state), do: state
  defp dispatch_jobs(%{queue_depth: 0} = state), do: state

  defp dispatch_jobs(%{active_workers: active_workers, max_concurrency: max} = state)
       when map_size(active_workers) >= max,
       do: state

  defp dispatch_jobs(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, job}, queue} ->
        task_fun = fn -> state.worker_module.perform(job, state.worker_opts) end

        case DynamicSupervisor.start_child(state.worker_supervisor, {Task, task_fun}) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            remaining_depth = state.queue_depth - 1
            active_count = map_size(state.active_workers) + 1
            metadata = common_metadata(job, remaining_depth, active_count)
            telemetry(:started, %{count: 1}, metadata)
            log_pipeline(:info, "started", metadata)

            next_state = %{
              state
              | queue: queue,
                queue_depth: remaining_depth,
                active_workers:
                  Map.put(state.active_workers, ref, %{
                    job: job,
                    pid: pid,
                    started_at: System.monotonic_time()
                  })
            }

            dispatch_jobs(next_state)

          {:error, _reason} ->
            state
        end
    end
  end

  defp job_type({:error_event, _event}), do: :error_event
  defp job_type({:diagnostics_event, _report, _issues}), do: :diagnostics_event

  defp common_metadata(job, queue_depth, active_workers) do
    %{job_type: job_type(job), queue_depth: queue_depth, active_workers: active_workers}
  end

  defp telemetry(event, measurements, metadata) do
    :telemetry.execute([:mom, :pipeline, event], measurements, metadata)
  end

  defp completed_reason?(:normal), do: true
  defp completed_reason?(:noproc), do: true
  defp completed_reason?(_reason), do: false

  defp log_pipeline(level, lifecycle, metadata, measurements \\ %{}) do
    measurements_text =
      measurements
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
      |> Enum.join(" ")

    metadata_text =
      metadata
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
      |> Enum.join(" ")

    msg = "mom: pipeline #{lifecycle} #{metadata_text} #{measurements_text}" |> String.trim()

    Logger.log(level, msg)
  end
end
