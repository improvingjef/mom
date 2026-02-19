defmodule Mom.Pipeline do
  @moduledoc false

  use GenServer

  alias Mom.WorkerSupervisor

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
       completed_count: 0
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
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.active_workers, ref) do
      {nil, _active_workers} ->
        {:noreply, state}

      {_job, active_workers} ->
        next_state =
          state
          |> Map.put(:active_workers, active_workers)
          |> Map.update!(:completed_count, &(&1 + 1))
          |> dispatch_jobs()

        {:noreply, next_state}
    end
  end

  defp enqueue_job(_job, %{queue_depth: depth, queue_max_size: max} = _state) when depth < max,
    do: :ok

  defp enqueue_job(_job, %{overflow_policy: :drop_newest}), do: {:dropped, :newest}
  defp enqueue_job(_job, %{overflow_policy: :drop_oldest}), do: {:dropped, :oldest}

  defp maybe_state(job, %{queue_depth: depth, queue_max_size: max} = state) when depth < max do
    %{state | queue: :queue.in(job, state.queue), queue_depth: depth + 1}
  end

  defp maybe_state(_job, %{overflow_policy: :drop_newest} = state) do
    %{state | dropped_count: state.dropped_count + 1}
  end

  defp maybe_state(job, %{overflow_policy: :drop_oldest} = state) do
    {_removed, queue} = :queue.out(state.queue)

    %{
      state
      | queue: :queue.in(job, queue),
        dropped_count: state.dropped_count + 1
    }
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

            next_state = %{
              state
              | queue: queue,
                queue_depth: state.queue_depth - 1,
                active_workers: Map.put(state.active_workers, ref, job)
            }

            dispatch_jobs(next_state)

          {:error, _reason} ->
            state
        end
    end
  end
end
