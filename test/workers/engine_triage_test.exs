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

  defp config_fixture do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo", mode: :inproc)
    config
  end
end
