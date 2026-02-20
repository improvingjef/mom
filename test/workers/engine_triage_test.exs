defmodule Mom.Workers.EngineTriageTest do
  use ExUnit.Case, async: true

  alias Mom.{Config, Workers.EngineTriage}

  defmodule SlowEngine do
    def handle_log(%{parent: parent}, _config) do
      send(parent, {:engine_started, self()})

      receive do
        :finish -> :ok
      end
    end

    def handle_diagnostics(_report, _issues, _config), do: :ok
  end

  defmodule CrashingEngine do
    def handle_log(_event, _config), do: raise("boom")
    def handle_diagnostics(_report, _issues, _config), do: :ok
  end

  defmodule OrphaningEngine do
    def handle_log(%{parent: parent}, _config) do
      orphan =
        :proc_lib.spawn(fn ->
          send(parent, {:orphan_started, self(), Process.info(self(), :dictionary)})

          receive do
            :stop -> :ok
          end
        end)

      send(parent, {:engine_started, self()})
      send(parent, {:orphan_pid, orphan})

      receive do
        :finish -> :ok
      end
    end

    def handle_diagnostics(_report, _issues, _config), do: :ok
  end

  test "cancels long-running jobs when they exceed timeout" do
    config = config_fixture()

    assert :ok =
             EngineTriage.perform({:error_event, %{parent: self()}},
               config: config,
               engine_module: SlowEngine,
               job_timeout_ms: 20
             )

    assert_receive {:engine_started, engine_pid}, 200

    refute Process.alive?(engine_pid)
  end

  test "isolates engine crashes and still returns :ok" do
    config = config_fixture()

    assert :ok =
             EngineTriage.perform({:error_event, %{id: "err-1"}},
               config: config,
               engine_module: CrashingEngine,
               job_timeout_ms: 100
             )
  end

  test "detects and force-cleans orphan descendants on timeout and emits watchdog alert" do
    config = config_fixture()
    handler_id = "mom-engine-triage-watchdog-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:mom, :alert, :execution_watchdog],
        fn event, measurements, metadata, pid ->
          send(pid, {:watchdog_alert, event, measurements, metadata})
        end,
        self()
      )

    orphan_pid =
      try do
        assert :ok =
                 EngineTriage.perform({:error_event, %{parent: self()}},
                   config: config,
                   engine_module: OrphaningEngine,
                   job_timeout_ms: 20,
                   execution_watchdog_orphan_grace_ms: 10
                 )

        assert_receive {:engine_started, _engine_pid}, 200
        assert_receive {:orphan_pid, orphan_pid}, 200
        assert_receive {:orphan_started, ^orphan_pid, {:dictionary, dictionary}}, 200
        assert Keyword.get(dictionary, :"$ancestors", []) != []

        assert_receive {:watchdog_alert, [:mom, :alert, :execution_watchdog], %{count: 1},
                        metadata},
                       200

        assert metadata.status == :timeout
        assert metadata.timeout_ms == 20
        assert metadata.orphan_detected_count >= 1
        assert metadata.forced_cleanup_count >= 1
        orphan_pid
      after
        :telemetry.detach(handler_id)
      end

    Process.sleep(50)
    refute Process.alive?(orphan_pid)
  end

  defp config_fixture do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        mode: :inproc,
        actor_id: "mom-app[bot]",
        allowed_actor_ids: ["mom-app[bot]"]
      )

    config
  end
end
