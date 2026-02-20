defmodule Mom.Acceptance.MomCliWorkerLifecycleWatchdogScript do
  alias Mom.{Config, Workers.EngineTriage}

  defmodule OrphaningEngine do
    def handle_log(%{parent: parent}, _config) do
      orphan =
        :proc_lib.spawn(fn ->
          send(parent, {:orphan_started, self()})

          receive do
            :stop -> :ok
          end
        end)

      send(parent, {:orphan_pid, orphan})
      receive do: (:finish -> :ok)
    end

    def handle_diagnostics(_report, _issues, _config), do: :ok
  end

  def run do
    handler_id = "mom-acceptance-watchdog-alert-#{System.unique_integer([:positive])}"
    audit_handler_id = "mom-acceptance-watchdog-audit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:mom, :alert, :execution_watchdog],
        fn _event, _measurements, _metadata, pid ->
          send(pid, :watchdog_alert)
        end,
        self()
      )

    :ok =
      :telemetry.attach(
        audit_handler_id,
        [:mom, :audit, :execution_watchdog_alert],
        fn _event, _measurements, _metadata, pid ->
          send(pid, :watchdog_audit)
        end,
        self()
      )

    result =
      try do
        {:ok, config} =
          Config.from_opts(
            repo: "/tmp/repo",
            mode: :inproc,
            toolchain_node_version_override: "v24.6.0",
            toolchain_otp_version_override: "28.0.2"
          )

        :ok =
          EngineTriage.perform({:error_event, %{parent: self()}},
            config: config,
            engine_module: OrphaningEngine,
            job_timeout_ms: 20,
            execution_watchdog_enabled: true,
            execution_watchdog_orphan_grace_ms: 10
          )

        orphan_pid = receive_orphan_pid()
        Process.sleep(50)

        %{
          watchdog_alert_emitted: event_received?(:watchdog_alert),
          watchdog_audit_emitted: event_received?(:watchdog_audit),
          orphan_force_cleaned: not Process.alive?(orphan_pid)
        }
      after
        :telemetry.detach(handler_id)
        :telemetry.detach(audit_handler_id)
      end

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp receive_orphan_pid do
    receive do
      {:orphan_pid, orphan_pid} ->
        orphan_pid
    after
      1_000 ->
        raise "timed out waiting for orphan pid"
    end
  end

  defp event_received?(message) do
    receive do
      ^message -> true
    after
      1_000 -> false
    end
  end
end

Mom.Acceptance.MomCliWorkerLifecycleWatchdogScript.run()
