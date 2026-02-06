defmodule Mom.Runner do
  @moduledoc false

  alias Mom.{Beam, Config, Diagnostics, Engine}

  require Logger

  @spec start(Config.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Config{} = config) do
    if is_binary(config.git_ssh_command) do
      System.put_env("GIT_SSH_COMMAND", config.git_ssh_command)
    end

    _ = Mom.RateLimiter.ensure_table()

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)
        loop(config, %{last_triage_at: 0})
      end)

    {:ok, pid}
  end

  defp loop(%Config{} = config, state) do
    :ok = ensure_connection(config)
    :ok = Beam.attach_logger(config, self())

    diagnostics_ref =
      Process.send_after(self(), :poll_diagnostics, config.poll_interval_ms)

    receive do
      {:mom_log, event} ->
        Logger.debug("mom: received error log")
        Engine.handle_log(event, config)
        loop(config, state)

      :poll_diagnostics ->
        {report, issues, triage?, now} = Diagnostics.poll(config, state.last_triage_at)
        if triage? do
          Engine.handle_diagnostics(report, issues, config)
        end

        Process.send_after(self(), :poll_diagnostics, config.poll_interval_ms)
        last_triage_at = if triage?, do: now, else: state.last_triage_at
        loop(config, %{state | last_triage_at: last_triage_at})

      {:EXIT, _pid, reason} ->
        Logger.warning("mom: exit #{inspect(reason)}")
        _ = diagnostics_ref
        loop(config, state)
    end
  end

  defp ensure_connection(%Config{mode: :inproc}), do: :ok

  defp ensure_connection(%Config{mode: :remote, node: node, cookie: cookie}) do
    with :ok <- Beam.ensure_node_started(cookie),
         true <- is_atom(node),
         true <- Node.connect(node) do
      :ok
    else
      false -> raise "failed to connect to node #{inspect(node)}"
      _ -> raise "node is required in remote mode"
    end
  end
end
