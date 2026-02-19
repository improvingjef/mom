defmodule Mom.Workers.EngineTriage do
  @moduledoc false

  require Logger

  @default_timeout_ms 120_000

  @spec perform(
          {:error_event, map()} | {:diagnostics_event, map(), list()},
          keyword()
        ) :: :ok
  def perform(job, opts) do
    config = Keyword.fetch!(opts, :config)
    timeout_ms = Keyword.get(opts, :job_timeout_ms, @default_timeout_ms)
    engine_module = Keyword.get(opts, :engine_module, Mom.Engine)
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      task =
        Task.async(fn ->
          execute(job, config, engine_module)
        end)

      case Task.yield(task, timeout_ms) do
        {:ok, :ok} ->
          :ok

        {:ok, other} ->
          Logger.warning("mom: worker finished with unexpected result #{inspect(other)}")
          :ok

        {:exit, reason} ->
          Logger.error("mom: worker crashed #{inspect(reason)}")
          :ok

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          Logger.error("mom: worker timed out after #{timeout_ms}ms")
          :ok
      end
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  end

  defp execute({:error_event, event}, config, engine_module) do
    engine_module.handle_log(event, config)
  end

  defp execute({:diagnostics_event, report, issues}, config, engine_module) do
    engine_module.handle_diagnostics(report, issues, config)
  end
end
