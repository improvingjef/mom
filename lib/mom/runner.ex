defmodule Mom.Runner do
  @moduledoc false

  alias Mom.{Beam, Config, Diagnostics, Pipeline}

  require Logger

  @spec start(Config.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Config{} = config), do: start(config, [])

  @spec start(Config.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(%Config{} = config, opts) do
    beam_module = Keyword.get(opts, :beam_module, Beam)
    diagnostics_module = Keyword.get(opts, :diagnostics_module, Diagnostics)
    pipeline_module = Keyword.get(opts, :pipeline_module, Pipeline)
    worker_module = Keyword.get(opts, :worker_module, Mom.Workers.EngineTriage)
    worker_opts = Keyword.get(opts, :worker_opts, [])

    pipeline_opts = [
      dispatch?: true,
      max_concurrency: Keyword.get(opts, :max_concurrency, config.max_concurrency),
      queue_max_size: Keyword.get(opts, :queue_max_size, config.queue_max_size),
      overflow_policy: Keyword.get(opts, :overflow_policy, config.overflow_policy),
      worker_module: worker_module,
      worker_opts: Keyword.merge([config: config, job_timeout_ms: config.job_timeout_ms], worker_opts)
    ]

    with {:ok, pipeline} <- pipeline_module.start_link(pipeline_opts) do
      do_start(config, pipeline, beam_module, diagnostics_module, pipeline_module)
    end
  end

  defp do_start(%Config{} = config, pipeline, beam_module, diagnostics_module, pipeline_module) do
    maybe_set_git_ssh_command(config)
    _ = Mom.RateLimiter.ensure_table()

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)

        loop(config, %{
          last_triage_at: 0,
          pipeline: pipeline,
          beam_module: beam_module,
          diagnostics_module: diagnostics_module,
          pipeline_module: pipeline_module
        })
      end)

    {:ok, pid}
  end

  defp maybe_set_git_ssh_command(%Config{} = config) do
    if is_binary(config.git_ssh_command) do
      System.put_env("GIT_SSH_COMMAND", config.git_ssh_command)
    end
  end

  defp loop(%Config{} = config, state) do
    :ok = ensure_connection(config, state.beam_module)
    :ok = state.beam_module.attach_logger(config, self())

    diagnostics_ref =
      Process.send_after(self(), :poll_diagnostics, config.poll_interval_ms)

    receive do
      {:mom_log, event} ->
        Logger.debug("mom: received error log")
        enqueue_job(state.pipeline_module, state.pipeline, {:error_event, event})
        loop(config, state)

      :poll_diagnostics ->
        {report, issues, triage?, now} =
          state.diagnostics_module.poll(config, state.last_triage_at)

        if triage? do
          enqueue_job(state.pipeline_module, state.pipeline, {:diagnostics_event, report, issues})
        end

        Process.send_after(self(), :poll_diagnostics, config.poll_interval_ms)
        last_triage_at = if triage?, do: now, else: state.last_triage_at
        loop(config, %{state | last_triage_at: last_triage_at})

      {:EXIT, _pid, reason} ->
        Logger.warning("mom: exit #{inspect(reason)}")
        _ = diagnostics_ref
        loop(config, state)
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

  defp ensure_connection(%Config{mode: :inproc}, _beam_module), do: :ok

  defp ensure_connection(%Config{mode: :remote, node: node, cookie: cookie}, beam_module) do
    with :ok <- beam_module.ensure_node_started(cookie),
         true <- is_atom(node),
         true <- Node.connect(node) do
      :ok
    else
      false -> raise "failed to connect to node #{inspect(node)}"
      _ -> raise "node is required in remote mode"
    end
  end
end
