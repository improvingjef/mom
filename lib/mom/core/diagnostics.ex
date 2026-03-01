defmodule Mom.Diagnostics do
  @moduledoc """
  Event-driven diagnostics evaluation.

  Evaluates incoming telemetry and system_monitor events against configured
  thresholds. Returns triage decisions without performing any I/O or RPC.
  """

  alias Mom.Config

  require Logger

  @doc """
  Evaluate a VM telemetry event (memory, run_queue) against thresholds.
  Returns `{issues, trigger?, now}`.
  """
  def evaluate_vm_event(event, %Config{} = config, last_triage_at) do
    issues = vm_issues(event, config)
    triage_decision(issues, config, last_triage_at)
  end

  @doc """
  Evaluate a system_monitor event (long_gc, long_schedule, busy_port).
  Always considered an issue worth reporting.
  """
  def evaluate_system_monitor(event, %Config{} = config, last_triage_at) do
    issues = [{event.type, event.info}]
    triage_decision(issues, config, last_triage_at)
  end

  @doc """
  Evaluate a Phoenix exception event. Always triggers triage.
  """
  def evaluate_exception(event, %Config{} = config, last_triage_at) do
    kind = get_in(event, [:metadata, :kind]) || :error
    reason = get_in(event, [:metadata, :reason])
    issues = [{:request_exception, kind, reason}]
    triage_decision(issues, config, last_triage_at)
  end

  @doc """
  Evaluate an Ecto query event for slow queries.
  """
  def evaluate_query(event, %Config{} = _config, last_triage_at) do
    total_time = get_in(event, [:measurements, :total_time]) || 0
    # Convert native time to ms
    total_ms = System.convert_time_unit(total_time, :native, :millisecond)

    if total_ms > 1000 do
      issues = [{:slow_query, total_ms, get_in(event, [:metadata, :source])}]
      now = System.monotonic_time(:millisecond)
      {issues, true, now}
    else
      {[], false, last_triage_at}
    end
  end

  @doc "Build a snapshot report from VM telemetry measurements."
  def snapshot_from_vm_events(memory_event, run_queue_event) do
    %{
      memory: memory_event[:measurements] || %{},
      run_queue: get_in(run_queue_event || %{}, [:measurements, :total]) || 0,
      node: memory_event[:node],
      at: memory_event[:at]
    }
  end

  @doc "Collect BEAM stats locally (used in :inproc mode)."
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

  def hot_processes(limit \\ 5) do
    :erlang.processes()
    |> Enum.map(fn pid ->
      info = :erlang.process_info(pid, [:reductions, :message_queue_len, :current_function])
      {pid, info[:reductions] || 0, info[:message_queue_len] || 0, info[:current_function]}
    end)
    |> Enum.sort_by(fn {_pid, reds, qlen, _} -> {reds, qlen} end, :desc)
    |> Enum.take(limit)
  end

  # -- Private --

  defp vm_issues(event, %Config{} = config) do
    issues = []
    measurements = event[:measurements] || %{}

    issues =
      case event[:event] do
        [:vm, :total_run_queue_lengths] ->
          total = measurements[:total] || 0
          # Use 2 as default scheduler count for threshold comparison
          schedulers = measurements[:cpu] || 2

          if total > schedulers * config.diagnostics.diag_run_queue_mult do
            [{:run_queue_high, total, schedulers, config.diagnostics.diag_run_queue_mult} | issues]
          else
            issues
          end

        [:vm, :memory] ->
          mem = measurements[:total] || 0

          if mem > config.diagnostics.diag_mem_high_bytes do
            [{:memory_high, mem, config.diagnostics.diag_mem_high_bytes} | issues]
          else
            issues
          end

        _ ->
          issues
      end

    Enum.reverse(issues)
  end

  defp triage_decision(issues, %Config{} = config, last_triage_at) do
    now = System.monotonic_time(:millisecond)

    trigger? =
      config.diagnostics.triage_on_diagnostics and issues != [] and
        now - last_triage_at >= config.diagnostics.diag_cooldown_ms

    if issues != [] do
      Logger.warning("mom: diagnostics issues #{inspect(issues)}")
    end

    {issues, trigger?, now}
  end
end
