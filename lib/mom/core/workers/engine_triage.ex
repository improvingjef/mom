defmodule Mom.Workers.EngineTriage do
  @moduledoc false

  alias Mom.Audit

  require Logger

  @default_timeout_ms 120_000
  @default_orphan_grace_ms 250

  @spec perform(
          {:error_event, map()} | {:diagnostics_event, map(), list()},
          keyword()
        ) :: :ok
  def perform(job, opts) do
    config = Keyword.fetch!(opts, :config)
    timeout_ms = Keyword.get(opts, :job_timeout_ms, @default_timeout_ms)
    watchdog_enabled = Keyword.get(opts, :execution_watchdog_enabled, true)
    orphan_grace_ms = Keyword.get(opts, :execution_watchdog_orphan_grace_ms, @default_orphan_grace_ms)
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
          {orphan_detected_count, forced_cleanup_count} =
            if watchdog_enabled do
              cleanup_orphan_descendants(task, orphan_grace_ms)
            else
              _ = Task.shutdown(task, :brutal_kill)
              {0, 0}
            end

          emit_execution_watchdog_alert(%{
            status: :timeout,
            timeout_ms: timeout_ms,
            orphan_detected_count: orphan_detected_count,
            forced_cleanup_count: forced_cleanup_count
          })

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

  defp cleanup_orphan_descendants(%Task{pid: task_pid} = task, orphan_grace_ms) when is_pid(task_pid) do
    descendants =
      find_descendant_processes(task_pid)
      |> Enum.reject(&(&1 == self()))
      |> Enum.uniq()

    _ = Task.shutdown(task, :brutal_kill)
    Process.sleep(max(orphan_grace_ms, 0))

    alive_orphans = Enum.filter(descendants, &Process.alive?/1)
    Enum.each(alive_orphans, &Process.exit(&1, :kill))

    {length(descendants), length(alive_orphans)}
  end

  defp find_descendant_processes(task_pid) do
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, [:dictionary, :links]) do
        nil ->
          false

        info ->
          ancestors =
            info
            |> Keyword.get(:dictionary, [])
            |> Keyword.get(:"$ancestors", [])

          links = Keyword.get(info, :links, [])
          Enum.member?(ancestors, task_pid) or Enum.member?(links, task_pid)
      end
    end)
  end

  defp emit_execution_watchdog_alert(metadata) do
    :telemetry.execute([:mom, :alert, :execution_watchdog], %{count: 1}, metadata)
    :ok = Audit.emit(:execution_watchdog_alert, metadata)
  end
end
