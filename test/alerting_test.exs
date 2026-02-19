defmodule Mom.AlertingTest do
  use ExUnit.Case, async: false

  alias Mom.Audit

  setup do
    handler_id = "mom-alerting-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:mom, :alert, :unusual_activity],
        fn event, measurements, metadata, pid ->
          send(pid, {:alert_event, event, measurements, metadata})
        end,
        self()
      )

    Application.put_env(:mom, :alert_window_ms, 60_000)
    Application.put_env(:mom, :alert_pr_spike_threshold, 2)
    Application.put_env(:mom, :alert_auth_failure_threshold, 2)

    reset_table()

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.delete_env(:mom, :alert_window_ms)
      Application.delete_env(:mom, :alert_pr_spike_threshold)
      Application.delete_env(:mom, :alert_auth_failure_threshold)
      reset_table()
    end)

    :ok
  end

  test "emits unusual activity alert when PR creation spikes" do
    :ok = Audit.emit(:github_pr_created, %{repo: "acme/mom", actor_id: "mom-bot", pr_number: 1})
    :ok = Audit.emit(:github_pr_created, %{repo: "acme/mom", actor_id: "mom-bot", pr_number: 2})

    assert_receive {:alert_event, [:mom, :alert, :unusual_activity], %{count: 1}, metadata}
    assert metadata.alert_type == :pr_spike
    assert metadata.repo == "acme/mom"
    assert metadata.actor_id == "mom-bot"
    assert metadata.threshold == 2

    :ok = Audit.emit(:github_pr_created, %{repo: "acme/mom", actor_id: "mom-bot", pr_number: 3})
    refute_receive {:alert_event, [:mom, :alert, :unusual_activity], _, _}
  end

  test "emits unusual activity alert on repeated auth failures" do
    :ok =
      Audit.emit(:github_pr_failed, %{
        repo: "acme/mom",
        actor_id: "mom-bot",
        reason: "{:http_error, 401, \"unauthorized\"}"
      })

    :ok =
      Audit.emit(:github_pr_failed, %{
        repo: "acme/mom",
        actor_id: "mom-bot",
        reason: "{:http_error, 403, \"forbidden\"}"
      })

    assert_receive {:alert_event, [:mom, :alert, :unusual_activity], %{count: 1}, metadata}
    assert metadata.alert_type == :auth_failure_spike
    assert metadata.repo == "acme/mom"
    assert metadata.actor_id == "mom-bot"
    assert metadata.threshold == 2
  end

  test "emits unusual activity alert for disallowed repo target attempts" do
    :ok =
      Audit.emit(:github_repo_disallowed, %{
        repo: "evil/repo",
        actor_id: "mom-bot",
        allowed_repos: ["acme/mom"]
      })

    assert_receive {:alert_event, [:mom, :alert, :unusual_activity], %{count: 1}, metadata}
    assert metadata.alert_type == :disallowed_repo_target
    assert metadata.repo == "evil/repo"
    assert metadata.actor_id == "mom-bot"
  end

  defp reset_table do
    case :ets.whereis(:mom_alerting) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end
  end
end
