defmodule Mom.Runner do
  @moduledoc false

  alias Mom.{Beam, Config, Diagnostics, Observability, Pipeline}

  require Logger

  @spec start(Config.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Config{} = config), do: start(config, [])

  @doc """
  Starts the event loop for one target node.

  Options used by the multi-target service (`Mom.Targets.Watcher`); `mix mom`
  uses none of them and keeps the old behaviour:

    * `:hooks` - map with any of `:before_connect` (fn -> any),
      `:on_connect` (fn config -> config, after each connect and handler
      install; the returned config goes to the pipeline workers),
      `:on_down` (fn node -> any) and `:on_event` (fn message -> any).
    * `:retry_connect` - when `true`, a failed first connect retries with
      backoff instead of crashing the loop. Default `false`.
    * `:backoff` - fn attempt -> milliseconds to wait before reconnect
      attempt `attempt` (0, 1, ...). Default: `poll_interval_ms`.
  """
  @spec start(Config.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(%Config{} = config, opts) do
    beam_module = Keyword.get(opts, :beam_module, Beam)
    diagnostics_module = Keyword.get(opts, :diagnostics_module, Diagnostics)
    pipeline_module = Keyword.get(opts, :pipeline_module, Pipeline)
    worker_module = Keyword.get(opts, :worker_module, Mom.Workers.EngineTriage)
    worker_opts = Keyword.get(opts, :worker_opts, [])

    pipeline_opts = [
      dispatch?: true,
      max_concurrency: Keyword.get(opts, :max_concurrency, config.pipeline.max_concurrency),
      queue_max_size: Keyword.get(opts, :queue_max_size, config.pipeline.queue_max_size),
      tenant_queue_max_size:
        Keyword.get(opts, :tenant_queue_max_size, config.pipeline.tenant_queue_max_size),
      overflow_policy: Keyword.get(opts, :overflow_policy, config.pipeline.overflow_policy),
      durable_queue_path:
        Keyword.get(opts, :durable_queue_path, config.pipeline.durable_queue_path),
      worker_module: worker_module,
      worker_opts:
        Keyword.merge(
          [
            config: config,
            job_timeout_ms: config.pipeline.job_timeout_ms,
            execution_watchdog_enabled: config.pipeline.execution_watchdog_enabled,
            execution_watchdog_orphan_grace_ms: config.pipeline.execution_watchdog_orphan_grace_ms
          ],
          worker_opts
        )
    ]

    with {:ok, pipeline} <- pipeline_module.start_link(pipeline_opts),
         :ok <- maybe_start_observability(config) do
      state = %{
        last_triage_at: 0,
        pipeline: pipeline,
        beam_module: beam_module,
        diagnostics_module: diagnostics_module,
        pipeline_module: pipeline_module,
        hooks: Map.merge(default_hooks(), Keyword.get(opts, :hooks, %{})),
        backoff: Keyword.get(opts, :backoff, fn _attempt -> config.runtime.poll_interval_ms end)
      }

      do_start(config, state, Keyword.get(opts, :retry_connect, false))
    end
  end

  defp default_hooks do
    %{
      before_connect: fn -> :ok end,
      on_connect: fn config -> config end,
      on_down: fn _node -> :ok end,
      on_event: fn _message -> :ok end
    }
  end

  defp do_start(%Config{} = config, state, retry_connect?) do
    maybe_set_git_ssh_command(config)
    maybe_set_audit_compliance_runtime(config)
    _ = Mom.RateLimiter.ensure_table()

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)

        if retry_connect? do
          case try_connect(config, state) do
            {:ok, config} ->
              Logger.info("mom: event-driven loop started for #{inspect(config.runtime.node)}")
              loop(config, state)

            :error ->
              Logger.warning("mom: cannot reach #{inspect(config.runtime.node)}, retrying")
              state.hooks.on_down.(config.runtime.node)
              reconnect(config, state)
          end
        else
          # Connect and install all handlers once up front
          state.hooks.before_connect.()
          :ok = ensure_connection(config, state.beam_module)
          config = attach_handlers(config, state)

          Logger.info("mom: event-driven loop started, listening for telemetry + logs")

          loop(config, state)
        end
      end)

    {:ok, pid}
  end

  defp try_connect(%Config{} = config, state) do
    state.hooks.before_connect.()
    :ok = ensure_connection(config, state.beam_module)
    {:ok, attach_handlers(config, state)}
  rescue
    _ -> :error
  end

  defp attach_handlers(%Config{} = config, state) do
    :ok = state.beam_module.attach_logger(config, self())
    :ok = state.beam_module.attach_telemetry(config, self())
    :ok = state.beam_module.monitor_node(config)

    case state.hooks.on_connect.(config) do
      ^config ->
        config

      %Config{} = new_config ->
        if function_exported?(state.pipeline_module, :put_worker_config, 2) do
          :ok = state.pipeline_module.put_worker_config(state.pipeline, new_config)
        end

        new_config
    end
  end

  defp maybe_set_git_ssh_command(%Config{} = config) do
    if is_binary(config.compliance.git_ssh_command) do
      System.put_env("GIT_SSH_COMMAND", config.compliance.git_ssh_command)
    end
  end

  defp maybe_set_audit_compliance_runtime(%Config{} = config) do
    Application.put_env(:mom, :redact_keys, config.compliance.redact_keys)
    Application.put_env(:mom, :audit_retention_days, config.compliance.audit_retention_days)
    Application.put_env(:mom, :soc2_evidence_path, config.compliance.soc2_evidence_path)
    Application.put_env(:mom, :pii_handling_policy, config.compliance.pii_handling_policy)
  end

  defp loop(%Config{} = config, state) do
    receive do
      {tag, _event} = message
      when tag in [:mom_log, :mom_telemetry, :mom_system_monitor] ->
        state.hooks.on_event.(message)
        loop(config, handle_event(message, config, state))

      # === Distributed Erlang heartbeat failure ===
      {:nodedown, node} ->
        Logger.error("mom: node down #{inspect(node)}, attempting reconnect")
        state.hooks.on_down.(node)
        reconnect(config, state)

      {:EXIT, _pid, reason} ->
        Logger.warning("mom: exit #{inspect(reason)}")
        loop(config, state)
    end
  end

  # === Error logs from RemoteLoggerHandler ===
  defp handle_event({:mom_log, event}, _config, state) do
    Logger.debug("mom: received error log")
    enqueue_job(state.pipeline_module, state.pipeline, {:error_event, event})
    state
  end

  # === VM telemetry — memory and run queue from telemetry_poller ===
  defp handle_event({:mom_telemetry, %{event: [:vm, _]} = event}, config, state) do
    {_issues, trigger?, now} =
      state.diagnostics_module.evaluate_vm_event(event, config, state.last_triage_at)

    maybe_enqueue_diagnostics(trigger?, event, now, state)
  end

  # === Phoenix exceptions ===
  defp handle_event(
         {:mom_telemetry, %{event: [:phoenix, :router_dispatch, :exception]} = event},
         config,
         state
       ) do
    {_issues, trigger?, now} =
      state.diagnostics_module.evaluate_exception(event, config, state.last_triage_at)

    maybe_enqueue_diagnostics(trigger?, event, now, state)
  end

  # === Slow Ecto queries ===
  defp handle_event({:mom_telemetry, %{event: [:latte, :repo, :query]} = event}, config, state) do
    {_issues, trigger?, _now} =
      state.diagnostics_module.evaluate_query(event, config, state.last_triage_at)

    if trigger? do
      enqueue_job(state.pipeline_module, state.pipeline, {:diagnostics_event, event, []})
    end

    state
  end

  # === Oban job failures ===
  defp handle_event({:mom_telemetry, %{event: [:oban, :job, :exception]} = event}, _config, state) do
    Logger.warning("mom: oban job exception")
    enqueue_job(state.pipeline_module, state.pipeline, {:error_event, event})
    state
  end

  # === Other telemetry — pass through silently ===
  defp handle_event({:mom_telemetry, _event}, _config, state), do: state

  # === System monitor events (long GC, busy ports) ===
  defp handle_event({:mom_system_monitor, event}, config, state) do
    Logger.warning("mom: system_monitor #{event.type}")

    {_issues, trigger?, now} =
      state.diagnostics_module.evaluate_system_monitor(event, config, state.last_triage_at)

    maybe_enqueue_diagnostics(trigger?, event, now, state)
  end

  defp maybe_enqueue_diagnostics(true, event, now, state) do
    enqueue_job(state.pipeline_module, state.pipeline, {:diagnostics_event, event, []})
    %{state | last_triage_at: now}
  end

  defp maybe_enqueue_diagnostics(_trigger?, _event, _now, state), do: state

  defp reconnect(%Config{} = config, state), do: reconnect(config, state, 0)

  defp reconnect(%Config{} = config, state, attempt) do
    Process.sleep(state.backoff.(attempt))

    case try_connect(config, state) do
      {:ok, config} ->
        Logger.info("mom: reconnected to #{inspect(config.runtime.node)}")
        loop(config, state)

      :error ->
        Logger.warning("mom: reconnect failed, retrying in #{state.backoff.(attempt + 1)}ms")

        reconnect(config, state, attempt + 1)
    end
  end

  defp enqueue_job(pipeline_module, pipeline, job) do
    case pipeline_module.enqueue(pipeline, job) do
      :ok ->
        :ok

      {:dropped, reason} ->
        Logger.warning("mom: job dropped due to queue overflow #{inspect(reason)}")
        :ok

      {:error, reason} ->
        Logger.warning("mom: invalid pipeline job #{inspect(reason)}")
        :ok
    end
  end

  defp ensure_connection(%Config{runtime: %{mode: :inproc}}, _beam_module), do: :ok

  defp ensure_connection(
         %Config{runtime: %{mode: :remote, node: node, cookie: cookie}},
         beam_module
       ) do
    with :ok <- beam_module.ensure_node_started(cookie),
         true <- is_atom(node),
         true <- Node.connect(node) do
      :ok
    else
      false -> raise "failed to connect to node #{inspect(node)}"
      _ -> raise "node is required in remote mode"
    end
  end

  defp maybe_start_observability(%Config{observability: %{backend: :none}}), do: :ok

  defp maybe_start_observability(%Config{observability: %{backend: :prometheus}} = config) do
    case Observability.start_link(
           export_path: config.observability.export_path,
           export_interval_ms: config.observability.export_interval_ms,
           queue_depth_threshold: config.observability.slo_queue_depth_threshold,
           drop_rate_threshold: config.observability.slo_drop_rate_threshold,
           failure_rate_threshold: config.observability.slo_failure_rate_threshold,
           latency_p95_ms_threshold: config.observability.slo_latency_p95_ms_threshold,
           triage_latency_p95_ms_target: config.observability.sla_triage_latency_p95_ms_target,
           queue_durability_target: config.observability.sla_queue_durability_target,
           pr_turnaround_p95_ms_target: config.observability.sla_pr_turnaround_p95_ms_target,
           triage_latency_overage_budget_rate:
             config.observability.error_budget_triage_latency_overage_rate,
           queue_loss_budget_rate: config.observability.error_budget_queue_loss_rate,
           pr_turnaround_overage_budget_rate:
             config.observability.error_budget_pr_turnaround_overage_rate
         ) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_start_observability(%Config{}), do: :ok
end
