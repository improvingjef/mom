defmodule Mom.RemoteTelemetryHandler do
  @moduledoc """
  Injected onto the remote BEAM node to forward telemetry events to Mom.

  Attaches to Phoenix, Ecto, Oban, and VM telemetry events. Also installs
  an :erlang.system_monitor for long GCs and busy schedulers. Sends all
  events as messages to the Mom runner PID.

  Loaded via :code.load_binary — same pattern as RemoteLoggerHandler.
  """

  @handler_id :mom_telemetry

  @phoenix_events [
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :exception]
  ]

  @ecto_events [
    [:latte, :repo, :query]
  ]

  @oban_events [
    [:oban, :job, :exception],
    [:oban, :job, :stop]
  ]

  @vm_events [
    [:vm, :memory],
    [:vm, :total_run_queue_lengths]
  ]

  @doc """
  Attach telemetry handlers and system monitor on the current (remote) node.
  Called via :rpc.call from Mom.
  """
  def attach(mom_pid) do
    # Detach previous handlers if any
    :telemetry.detach(@handler_id)

    all_events = @phoenix_events ++ @ecto_events ++ @oban_events ++ @vm_events

    :telemetry.attach_many(
      @handler_id,
      all_events,
      &__MODULE__.handle_event/4,
      %{mom_pid: mom_pid}
    )

    # Install system_monitor for long GCs and busy schedulers
    spawn(fn ->
      :erlang.system_monitor(self(), [
        {:long_gc, 50},
        {:long_schedule, 20},
        :busy_port,
        :busy_dist_port
      ])

      system_monitor_loop(mom_pid)
    end)

    :ok
  end

  @doc "Detach all handlers on the current node."
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc "Telemetry callback — forwards events to Mom."
  def handle_event(event_name, measurements, metadata, %{mom_pid: mom_pid}) do
    msg = %{
      event: event_name,
      measurements: measurements,
      metadata: sanitize_metadata(metadata),
      node: node(),
      at: System.system_time(:millisecond)
    }

    send(mom_pid, {:mom_telemetry, msg})
  end

  defp system_monitor_loop(mom_pid) do
    receive do
      {:monitor, pid, type, info} ->
        send(mom_pid, {:mom_system_monitor, %{
          type: type,
          pid: pid,
          info: info,
          node: node(),
          at: System.system_time(:millisecond)
        }})

        system_monitor_loop(mom_pid)
    end
  end

  # Strip non-serializable metadata (pids, refs, funs, sockets)
  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop([:conn, :socket, :telemetry_span_context, :stacktrace])
    |> Map.new(fn {k, v} -> {k, sanitize_value(v)} end)
  end

  defp sanitize_metadata(other), do: other

  defp sanitize_value(v) when is_pid(v), do: inspect(v)
  defp sanitize_value(v) when is_reference(v), do: inspect(v)
  defp sanitize_value(v) when is_port(v), do: inspect(v)
  defp sanitize_value(v) when is_function(v), do: inspect(v)
  defp sanitize_value(v), do: v
end
