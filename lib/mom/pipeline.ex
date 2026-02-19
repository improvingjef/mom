defmodule Mom.Pipeline do
  @moduledoc false

  use GenServer

  @type overflow_policy :: :drop_newest | :drop_oldest
  @type supported_job ::
          {:error_event, map()}
          | {:diagnostics_event, map(), list()}

  @type enqueue_result :: :ok | {:dropped, :newest | :oldest} | {:error, :invalid_job}

  @default_queue_max_size 200
  @default_overflow_policy :drop_newest

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
          dropped_count: non_neg_integer(),
          queue_max_size: pos_integer(),
          overflow_policy: overflow_policy()
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

    {:ok,
     %{
       queue: :queue.new(),
       queue_depth: 0,
       queue_max_size: queue_max_size,
       overflow_policy: overflow_policy,
       dropped_count: 0
     }}
  end

  @impl true
  def handle_call({:enqueue, job}, _from, state) do
    if valid_job?(job) do
      {:reply, enqueue_job(job, state), maybe_state(job, state)}
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
       dropped_count: state.dropped_count,
       queue_max_size: state.queue_max_size,
       overflow_policy: state.overflow_policy
     }, state}
  end

  defp enqueue_job(_job, %{queue_depth: depth, queue_max_size: max} = _state) when depth < max, do: :ok
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
  defp valid_job?({:diagnostics_event, report, issues}) when is_map(report) and is_list(issues), do: true
  defp valid_job?(_job), do: false

  defp normalize_queue_max_size(size) when is_integer(size) and size > 0, do: size
  defp normalize_queue_max_size(_size), do: @default_queue_max_size

  defp normalize_overflow_policy(:drop_newest), do: :drop_newest
  defp normalize_overflow_policy(:drop_oldest), do: :drop_oldest
  defp normalize_overflow_policy(_policy), do: @default_overflow_policy
end
