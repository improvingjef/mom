defmodule Mom.Pipeline do
  @moduledoc false

  use GenServer

  alias Mom.WorkerSupervisor
  require Logger

  @type overflow_policy :: :drop_newest | :drop_oldest
  @type supported_job ::
          {:error_event, map()}
          | {:diagnostics_event, map(), list()}

  @type enqueue_result ::
          :ok
          | {:dropped, :newest | :oldest | :inflight | :tenant_quota}
          | {:error, :invalid_job}

  @default_queue_max_size 200
  @default_overflow_policy :drop_newest
  @default_max_concurrency 4
  @default_tenant "__default__"

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
          tenant_queue_max_size: pos_integer() | nil,
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

    tenant_queue_max_size =
      opts
      |> Keyword.get(:tenant_queue_max_size)
      |> normalize_tenant_queue_max_size()

    durable_queue_path =
      opts
      |> Keyword.get(:durable_queue_path)
      |> normalize_durable_queue_path()

    dispatch? = Keyword.get(opts, :dispatch?, false)
    worker_module = Keyword.get(opts, :worker_module)
    worker_opts = Keyword.get(opts, :worker_opts, [])
    worker_supervisor = maybe_start_worker_supervisor(opts, dispatch?)

    state = %{
      queue: :queue.new(),
      queue_depth: 0,
      queue_max_size: queue_max_size,
      tenant_queue_max_size: tenant_queue_max_size,
      tenant_queue_depths: %{},
      last_dispatched_tenant: nil,
      overflow_policy: overflow_policy,
      durable_queue_path: durable_queue_path,
      dropped_count: 0,
      dispatch?: dispatch?,
      worker_module: worker_module,
      worker_opts: worker_opts,
      worker_supervisor: worker_supervisor,
      max_concurrency: max_concurrency,
      active_workers: %{},
      inflight_signatures: MapSet.new(),
      completed_count: 0,
      failed_count: 0
    }

    {:ok, restore_persisted_queue(state), {:continue, :dispatch}}
  end

  @impl true
  def handle_call({:enqueue, job}, _from, state) do
    if valid_job?(job) do
      {result, next_state} = maybe_enqueue(job, state)
      {:reply, result, dispatch_jobs(next_state)}
    else
      {:reply, {:error, :invalid_job}, state}
    end
  end

  def handle_call(:dequeue, _from, %{queue_depth: 0} = state) do
    {:reply, :empty, state}
  end

  def handle_call(:dequeue, _from, state) do
    case pop_next_entry(state.queue, state.last_dispatched_tenant) do
      :empty ->
        {:reply, :empty, state}

      {:ok, {job, signature_key, tenant}, queue, last_dispatched_tenant} ->
        next_state = %{
          state
          | queue: queue,
            queue_depth: state.queue_depth - 1,
            tenant_queue_depths: decrement_tenant_depth(state.tenant_queue_depths, tenant),
            last_dispatched_tenant: last_dispatched_tenant,
            inflight_signatures: MapSet.delete(state.inflight_signatures, signature_key)
        }

        {:reply, {:ok, job}, persist_queue_snapshot(next_state)}
    end
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
       tenant_queue_max_size: state.tenant_queue_max_size,
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

      {%{job: job, started_at: started_at, signature_key: signature_key, tenant: tenant}, active_workers} ->
        now = System.monotonic_time()
        measurements = %{duration: now - started_at}

        metadata =
          common_metadata(
            job,
            tenant,
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
          |> Map.update!(:inflight_signatures, &MapSet.delete(&1, signature_key))
          |> dispatch_jobs()

        {:noreply, next_state}
    end
  end

  defp maybe_enqueue(job, state) do
    tenant = tenant_for_job(job)
    signature_key = dedupe_signature_key(job, tenant)

    cond do
      MapSet.member?(state.inflight_signatures, signature_key) ->
        next_state = increment_drop(state)

        metadata = %{
          drop_reason: :inflight,
          tenant: tenant,
          queue_depth: state.queue_depth,
          active_workers: map_size(state.active_workers)
        }

        telemetry(:dropped, %{count: 1}, metadata)
        log_pipeline(:warning, "dropped", metadata)
        {{:dropped, :inflight}, next_state}

      tenant_quota_exceeded?(tenant, state) ->
        next_state = increment_drop(state)

        metadata = %{
          drop_reason: :tenant_quota,
          tenant: tenant,
          queue_depth: state.queue_depth,
          active_workers: map_size(state.active_workers)
        }

        telemetry(:dropped, %{count: 1}, metadata)
        log_pipeline(:warning, "dropped", metadata)
        {{:dropped, :tenant_quota}, next_state}

      true ->
        enqueue_unique(job, signature_key, tenant, state)
    end
  end

  defp enqueue_unique(
         job,
         signature_key,
         tenant,
         %{queue_depth: depth, queue_max_size: max, tenant_queue_depths: tenant_depths} = state
       )
       when depth < max do
    next_tenant_depths = Map.update(tenant_depths, tenant, 1, &(&1 + 1))

    next_state = %{
      state
      | queue: :queue.in({job, signature_key, tenant}, state.queue),
        queue_depth: depth + 1,
        tenant_queue_depths: next_tenant_depths,
        inflight_signatures: MapSet.put(state.inflight_signatures, signature_key)
    }

    metadata = common_metadata(job, tenant, next_state.queue_depth, map_size(next_state.active_workers))
    telemetry(:enqueued, %{count: 1}, metadata)
    log_pipeline(:debug, "enqueued", metadata)
    {:ok, persist_queue_snapshot(next_state)}
  end

  defp enqueue_unique(_job, _signature_key, tenant, %{overflow_policy: :drop_newest} = state) do
    next_state = increment_drop(state)

    metadata = %{
      drop_reason: :newest,
      tenant: tenant,
      queue_depth: state.queue_depth,
      active_workers: map_size(state.active_workers)
    }

    telemetry(:dropped, %{count: 1}, metadata)
    log_pipeline(:warning, "dropped", metadata)
    {{:dropped, :newest}, next_state}
  end

  defp enqueue_unique(job, signature_key, tenant, %{overflow_policy: :drop_oldest} = state) do
    {{:value, {dropped_job, dropped_signature_key, dropped_tenant}}, queue} = :queue.out(state.queue)

    tenant_queue_depths =
      state.tenant_queue_depths
      |> decrement_tenant_depth(dropped_tenant)
      |> Map.update(tenant, 1, &(&1 + 1))

    next_state = %{
      state
      | queue: :queue.in({job, signature_key, tenant}, queue),
        dropped_count: state.dropped_count + 1,
        tenant_queue_depths: tenant_queue_depths,
        inflight_signatures:
          state.inflight_signatures
          |> MapSet.delete(dropped_signature_key)
          |> MapSet.put(signature_key)
    }

    metadata =
      common_metadata(job, tenant, state.queue_depth, map_size(state.active_workers))
      |> Map.put(:drop_reason, :oldest)
      |> Map.put(:dropped_job_type, job_type(dropped_job))
      |> Map.put(:dropped_tenant, dropped_tenant)

    telemetry(:dropped, %{count: 1}, metadata)
    log_pipeline(:warning, "dropped", metadata)
    {{:dropped, :oldest}, persist_queue_snapshot(next_state)}
  end

  defp tenant_quota_exceeded?(_tenant, %{tenant_queue_max_size: nil}), do: false

  defp tenant_quota_exceeded?(tenant, state) do
    queued = Map.get(state.tenant_queue_depths, tenant, 0)
    active = tenant_active_count(state.active_workers, tenant)
    queued + active >= state.tenant_queue_max_size
  end

  defp tenant_active_count(active_workers, tenant) do
    active_workers
    |> Map.values()
    |> Enum.count(&(&1.tenant == tenant))
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

  defp normalize_tenant_queue_max_size(value) when is_integer(value) and value > 0, do: value
  defp normalize_tenant_queue_max_size(_value), do: nil

  defp normalize_durable_queue_path(path) when is_binary(path) do
    trimmed = String.trim(path)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_durable_queue_path(_path), do: nil

  defp restore_persisted_queue(%{durable_queue_path: nil} = state), do: state

  defp restore_persisted_queue(state) do
    jobs = read_persisted_jobs(state.durable_queue_path)

    next_state =
      Enum.reduce(jobs, state, fn job, acc ->
        restore_enqueue(job, acc)
      end)

    persist_queue_snapshot(next_state)
  end

  defp restore_enqueue(job, state) do
    tenant = tenant_for_job(job)
    signature_key = dedupe_signature_key(job, tenant)

    cond do
      MapSet.member?(state.inflight_signatures, signature_key) ->
        state

      tenant_quota_exceeded?(tenant, state) ->
        state

      state.queue_depth < state.queue_max_size ->
        %{
          state
          | queue: :queue.in({job, signature_key, tenant}, state.queue),
            queue_depth: state.queue_depth + 1,
            tenant_queue_depths: Map.update(state.tenant_queue_depths, tenant, 1, &(&1 + 1)),
            inflight_signatures: MapSet.put(state.inflight_signatures, signature_key)
        }

      state.overflow_policy == :drop_newest ->
        state

      true ->
        {{:value, {_dropped_job, dropped_signature_key, dropped_tenant}}, queue} =
          :queue.out(state.queue)

        %{
          state
          | queue: :queue.in({job, signature_key, tenant}, queue),
            tenant_queue_depths:
              state.tenant_queue_depths
              |> decrement_tenant_depth(dropped_tenant)
              |> Map.update(tenant, 1, &(&1 + 1)),
            inflight_signatures:
              state.inflight_signatures
              |> MapSet.delete(dropped_signature_key)
              |> MapSet.put(signature_key)
        }
    end
  end

  defp read_persisted_jobs(path) do
    case File.read(path) do
      {:ok, binary} ->
        case safe_decode_jobs(binary) do
          {:ok, jobs} ->
            Enum.filter(jobs, &valid_job?/1)

          {:error, reason} ->
            Logger.warning(
              "mom: pipeline durable queue decode failed #{inspect(reason)} path=#{path}"
            )

            []
        end

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("mom: pipeline durable queue read failed #{inspect(reason)} path=#{path}")
        []
    end
  end

  defp safe_decode_jobs(binary) do
    try do
      case :erlang.binary_to_term(binary, [:safe]) do
        jobs when is_list(jobs) -> {:ok, jobs}
        _other -> {:error, :invalid_payload}
      end
    rescue
      error -> {:error, error}
    end
  end

  defp persist_queue_snapshot(%{durable_queue_path: nil} = state), do: state

  defp persist_queue_snapshot(state) do
    jobs =
      state.queue
      |> :queue.to_list()
      |> Enum.map(fn {job, _signature_key, _tenant} -> job end)

    payload = :erlang.term_to_binary(jobs)
    path = state.durable_queue_path

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case File.write(path, payload) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "mom: pipeline durable queue persist failed #{inspect(reason)} path=#{path}"
            )
        end

      {:error, reason} ->
        Logger.warning("mom: pipeline durable queue mkdir failed #{inspect(reason)} path=#{path}")
    end

    state
  end

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
    case pop_next_entry(state.queue, state.last_dispatched_tenant) do
      :empty ->
        state

      {:ok, {job, signature_key, tenant}, queue, last_dispatched_tenant} ->
        task_fun = fn -> state.worker_module.perform(job, state.worker_opts) end

        case DynamicSupervisor.start_child(state.worker_supervisor, {Task, task_fun}) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            remaining_depth = state.queue_depth - 1
            active_count = map_size(state.active_workers) + 1
            metadata = common_metadata(job, tenant, remaining_depth, active_count)
            telemetry(:started, %{count: 1}, metadata)
            log_pipeline(:info, "started", metadata)

            next_state =
              %{
                state
                | queue: queue,
                  queue_depth: remaining_depth,
                  tenant_queue_depths: decrement_tenant_depth(state.tenant_queue_depths, tenant),
                  last_dispatched_tenant: last_dispatched_tenant,
                  active_workers:
                    Map.put(state.active_workers, ref, %{
                      job: job,
                      pid: pid,
                      signature_key: signature_key,
                      tenant: tenant,
                      started_at: System.monotonic_time()
                    })
              }
              |> persist_queue_snapshot()

            dispatch_jobs(next_state)

          {:error, _reason} ->
            state
        end
    end
  end

  defp remove_first_for_tenant(entries, tenant), do: do_remove_first_for_tenant(entries, tenant, [])

  defp do_remove_first_for_tenant([], _tenant, _acc), do: :error

  defp do_remove_first_for_tenant([{job, signature_key, tenant} | rest], tenant, acc) do
    {:ok, {job, signature_key, tenant}, Enum.reverse(acc) ++ rest}
  end

  defp do_remove_first_for_tenant([entry | rest], tenant, acc) do
    do_remove_first_for_tenant(rest, tenant, [entry | acc])
  end

  defp queued_tenants(queue) do
    queue
    |> :queue.to_list()
    |> Enum.map(fn {_job, _signature_key, tenant} -> tenant end)
    |> Enum.uniq()
  end

  defp select_next_tenant([], _last_tenant), do: nil
  defp select_next_tenant(tenants, nil), do: hd(tenants)

  defp select_next_tenant(tenants, last_tenant) do
    case Enum.find_index(tenants, &(&1 == last_tenant)) do
      nil -> hd(tenants)
      idx -> Enum.at(tenants, rem(idx + 1, length(tenants)))
    end
  end

  defp pop_next_entry(queue, last_tenant) do
    tenants = queued_tenants(queue)

    case select_next_tenant(tenants, last_tenant) do
      nil ->
        :empty

      tenant ->
        case remove_first_for_tenant(:queue.to_list(queue), tenant) do
          {:ok, entry, remaining} ->
            {:ok, entry, :queue.from_list(remaining), tenant}

          :error ->
            :empty
        end
    end
  end

  defp decrement_tenant_depth(depths, tenant) do
    case Map.get(depths, tenant, 0) do
      value when value <= 1 -> Map.delete(depths, tenant)
      value -> Map.put(depths, tenant, value - 1)
    end
  end

  defp job_type({:error_event, _event}), do: :error_event
  defp job_type({:diagnostics_event, _report, _issues}), do: :diagnostics_event

  defp common_metadata(job, tenant, queue_depth, active_workers) do
    %{job_type: job_type(job), tenant: tenant, queue_depth: queue_depth, active_workers: active_workers}
  end

  defp telemetry(event, measurements, metadata) do
    :telemetry.execute([:mom, :pipeline, event], measurements, metadata)
  end

  defp completed_reason?(:normal), do: true
  defp completed_reason?(:noproc), do: true
  defp completed_reason?(_reason), do: false

  defp increment_drop(state), do: %{state | dropped_count: state.dropped_count + 1}

  defp tenant_for_job({:error_event, event}), do: tenant_from_map(event)
  defp tenant_for_job({:diagnostics_event, report, _issues}), do: tenant_from_map(report)

  defp dedupe_signature_key({:error_event, event}, tenant) do
    {tenant, Mom.Security.signature({:error_event, event})}
  end

  defp dedupe_signature_key({:diagnostics_event, report, issues}, tenant) do
    {tenant, Mom.Security.signature({:diagnostics_event, report, issues})}
  end

  defp tenant_from_map(map) when is_map(map) do
    repo = Map.get(map, :repo) || Map.get(map, "repo")

    case repo do
      value when is_binary(value) and value != "" -> value
      _other -> @default_tenant
    end
  end

  defp tenant_from_map(_), do: @default_tenant

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
