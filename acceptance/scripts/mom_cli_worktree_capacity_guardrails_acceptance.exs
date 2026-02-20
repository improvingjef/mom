defmodule Mom.Acceptance.MomCliWorktreeCapacityGuardrailsScript do
  alias Mom.{Config, Isolation, Runbook}

  def run do
    run_id = "acceptance/worktree-capacity-#{System.unique_integer([:positive])}"
    env = %{"MOM_WORKTREE_RUN_ID" => run_id, "MOM_WORKTREE_PID" => "capacity"}
    first_dir = Path.join(System.tmp_dir!(), Isolation.tmp_workdir_basename(1, env))
    second_dir = Path.join(System.tmp_dir!(), Isolation.tmp_workdir_basename(2, env))

    observed_handler_id = "mom-acceptance-temp-worktree-observed-#{System.unique_integer([:positive])}"
    alert_handler_id = "mom-acceptance-temp-worktree-alert-#{System.unique_integer([:positive])}"
    blocked_handler_id = "mom-acceptance-temp-worktree-blocked-#{System.unique_integer([:positive])}"
    backpressure_alert_handler_id =
      "mom-acceptance-temp-worktree-backpressure-alert-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        observed_handler_id,
        [:mom, :audit, :temp_worktree_capacity_observed],
        fn _event, _measurements, _metadata, pid ->
          send(pid, :observed)
        end,
        self()
      )

    :ok =
      :telemetry.attach(
        alert_handler_id,
        [:mom, :audit, :temp_worktree_capacity_alert],
        fn _event, _measurements, _metadata, pid ->
          send(pid, :alert)
        end,
        self()
      )

    :ok =
      :telemetry.attach(
        blocked_handler_id,
        [:mom, :audit, :temp_worktree_capacity_blocked],
        fn _event, _measurements, _metadata, pid ->
          send(pid, :blocked)
        end,
        self()
      )

    :ok =
      :telemetry.attach(
        backpressure_alert_handler_id,
        [:mom, :alert, :temp_worktree_capacity],
        fn _event, _measurements, metadata, pid ->
          status = Map.get(metadata, :status)

          case status do
            :alert -> send(pid, :backpressure_alert)
            :blocked -> send(pid, :backpressure_blocked)
            _ -> :ok
          end
        end,
        self()
      )

    File.rm_rf!(first_dir)
    File.rm_rf!(second_dir)
    File.mkdir_p!(first_dir)
    File.mkdir_p!(second_dir)
    {:ok, active_count} = Isolation.count_ephemeral_tmp_worktrees(System.tmp_dir!())
    max_active = max(active_count - 1, 1)

    Application.put_env(:mom, :temp_worktree_retention_seconds, 86_400)
    Application.put_env(:mom, :temp_worktree_keep_latest, 16)
    Application.put_env(:mom, :temp_worktree_max_active, max_active)
    Application.put_env(:mom, :temp_worktree_alert_utilization_threshold, 0.5)

    result =
      try do
        startup_blocked? =
          case Config.from_opts(
                 repo: "/tmp/repo",
                 mode: :inproc,
                 toolchain_node_version_override: "v24.6.0",
                 toolchain_otp_version_override: "28.0.2"
               ) do
            {:error, _reason} -> true
            {:ok, _config} -> false
          end

        %{
          startup_blocked: startup_blocked?,
          observed_event_emitted: event_received?(:observed),
          alert_event_emitted: event_received?(:alert),
          blocked_event_emitted: event_received?(:blocked),
          backpressure_alert_emitted: event_received?(:backpressure_alert),
          backpressure_blocked_emitted: event_received?(:backpressure_blocked),
          saturation_runbook_present:
            String.contains?(Runbook.render("2026-02-20"), "## Temp Worktree Saturation Response")
        }
      after
        :telemetry.detach(observed_handler_id)
        :telemetry.detach(alert_handler_id)
        :telemetry.detach(blocked_handler_id)
        :telemetry.detach(backpressure_alert_handler_id)
        Application.delete_env(:mom, :temp_worktree_retention_seconds)
        Application.delete_env(:mom, :temp_worktree_keep_latest)
        Application.delete_env(:mom, :temp_worktree_max_active)
        Application.delete_env(:mom, :temp_worktree_alert_utilization_threshold)
        File.rm_rf!(first_dir)
        File.rm_rf!(second_dir)
      end

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp event_received?(message) do
    receive do
      ^message -> true
    after
      1_000 -> false
    end
  end
end

Mom.Acceptance.MomCliWorktreeCapacityGuardrailsScript.run()
