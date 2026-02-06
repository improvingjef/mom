defmodule Mom.RemoteLoggerHandler do
  @moduledoc false

  @behaviour :logger_handler

  def init(%{mom_pid: mom_pid, min_level: min_level}) do
    {:ok, %{mom_pid: mom_pid, min_level: min_level}}
  end

  def log(%{level: level} = event, %{mom_pid: mom_pid, min_level: min_level} = state) do
    if level_allowed?(level, min_level) do
      send(mom_pid, {:mom_log, event})
    end

    {:ok, state}
  end

  def handle_call(_request, state), do: {:ok, :ok, state}
  def handle_event(_event, state), do: {:ok, state}
  def terminate(_reason, _state), do: :ok

  defp level_allowed?(level, min_level) do
    level_rank(level) >= level_rank(min_level)
  end

  defp level_rank(:debug), do: 0
  defp level_rank(:info), do: 1
  defp level_rank(:notice), do: 2
  defp level_rank(:warning), do: 3
  defp level_rank(:error), do: 4
  defp level_rank(:critical), do: 5
  defp level_rank(:alert), do: 6
  defp level_rank(:emergency), do: 7
  defp level_rank(_), do: 4
end
