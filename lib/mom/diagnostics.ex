defmodule Mom.Diagnostics do
  @moduledoc false

  alias Mom.Config

  require Logger

  @spec poll(Config.t(), non_neg_integer()) ::
          {map(), list(), boolean(), non_neg_integer()}
  def poll(%Config{mode: :inproc} = config, last_triage_at) do
    report = local_report()
    Logger.info("mom: diagnostics #{inspect(report)}")
    triage = maybe_triage(report, config, last_triage_at)
    {report, triage.issues, triage.trigger?, triage.now}
  end

  def poll(%Config{mode: :remote, node: node} = config, last_triage_at) do
    report = :rpc.call(node, __MODULE__, :local_report, [])
    Logger.info("mom: diagnostics #{inspect(report)}")
    triage = maybe_triage(report, config, last_triage_at)
    {report, triage.issues, triage.trigger?, triage.now}
  end

  def local_report do
    _ = :erlang.system_flag(:scheduler_wall_time, true)

    %{
      memory: :erlang.memory(),
      run_queue: :erlang.statistics(:run_queue),
      reductions: :erlang.statistics(:reductions),
      process_count: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online),
      scheduler_wall_time: :erlang.statistics(:scheduler_wall_time)
    }
  end

  defp maybe_triage(report, %Config{} = config, last_triage_at) do
    issues = health_issues(report, config)
    now = System.monotonic_time(:millisecond)

    trigger? =
      config.triage_on_diagnostics and issues != [] and
        now - last_triage_at >= config.diag_cooldown_ms

    if issues != [] do
      Logger.warning("mom: diagnostics issues #{inspect(issues)}")
    end

    %{issues: issues, trigger?: trigger?, now: now}
  end

  defp health_issues(report, %Config{} = config) do
    mem = report.memory[:total] || 0
    schedulers = report.schedulers || 1
    run_queue = report.run_queue || 0

    issues = []

    issues =
      if run_queue > schedulers * config.diag_run_queue_mult do
        [{:run_queue_high, run_queue, schedulers, config.diag_run_queue_mult} | issues]
      else
        issues
      end

    issues =
      if mem > config.diag_mem_high_bytes do
        [{:memory_high, mem, config.diag_mem_high_bytes} | issues]
      else
        issues
      end

    Enum.reverse(issues)
  end

  def hot_processes(limit \\ 5) do
    :erlang.processes()
    |> Enum.map(fn pid ->
      info = :erlang.process_info(pid, [:reductions, :message_queue_len, :current_function])
      {pid, info[:reductions] || 0, info[:message_queue_len] || 0, info[:current_function]}
    end)
    |> Enum.sort_by(fn {_pid, reds, qlen, _} -> {reds, qlen} end, :desc)
    |> Enum.take(limit)
  end
end
