defmodule Mom.AcceptanceLifecycle do
  @moduledoc """
  Utilities for identifying lingering Playwright-owned `mix run acceptance/scripts/*`
  processes from a process table snapshot, and for deterministic acceptance
  build-artifact isolation controls.
  """

  @type process_row :: %{pid: pos_integer(), ppid: pos_integer(), command: String.t()}
  @type build_artifact_mode :: :worker_isolated | :serialized

  @truthy_values ~w(1 true TRUE yes YES on ON)

  @spec parse_snapshot(String.t()) :: [process_row()]
  def parse_snapshot(snapshot) when is_binary(snapshot) do
    snapshot
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ~r/\s+/, parts: 3) do
        [pid_text, ppid_text, command] ->
          with {pid, ""} <- Integer.parse(pid_text),
               {ppid, ""} <- Integer.parse(ppid_text),
               true <- byte_size(command) > 0 do
            [%{pid: pid, ppid: ppid, command: command}]
          else
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  @spec descendants([process_row()], pos_integer()) :: [process_row()]
  def descendants(rows, root_pid) when is_list(rows) and is_integer(root_pid) do
    grouped = Enum.group_by(rows, & &1.ppid)

    walk_descendants(grouped, Map.get(grouped, root_pid, []), [])
    |> Enum.reverse()
  end

  @spec lingering_mix_run_children(String.t() | [process_row()], pos_integer()) :: [process_row()]
  def lingering_mix_run_children(snapshot_or_rows, root_pid)
      when is_integer(root_pid) do
    rows =
      case snapshot_or_rows do
        snapshot when is_binary(snapshot) -> parse_snapshot(snapshot)
        rows when is_list(rows) -> rows
      end

    rows
    |> descendants(root_pid)
    |> Enum.filter(&lingering_mix_run_command?/1)
  end

  @spec build_artifact_mode(map()) :: build_artifact_mode()
  def build_artifact_mode(env) when is_map(env) do
    mode = normalize_mode(Map.get(env, "MOM_ACCEPTANCE_BUILD_MODE"))

    cond do
      truthy?(Map.get(env, "MOM_ACCEPTANCE_SERIALIZED")) -> :serialized
      mode in [:worker_isolated, :serialized] -> mode
      true -> :worker_isolated
    end
  end

  @spec build_artifact_path(build_artifact_mode(), binary(), non_neg_integer()) :: binary()
  def build_artifact_path(mode, run_id, worker_index)
      when mode in [:worker_isolated, :serialized] and is_binary(run_id) and
             is_integer(worker_index) and worker_index >= 0 do
    case mode do
      :serialized ->
        "_build_acceptance_serialized_#{sanitize_segment(run_id)}"

      :worker_isolated ->
        "_build_acceptance_worker_#{sanitize_segment(run_id)}_#{worker_index}"
    end
  end

  defp walk_descendants(_grouped, [], acc), do: acc

  defp walk_descendants(grouped, [current | rest], acc) do
    children = Map.get(grouped, current.pid, [])
    walk_descendants(grouped, rest ++ children, [current | acc])
  end

  defp lingering_mix_run_command?(%{command: command}) do
    String.match?(command, ~r/\bmix\b/) and
      String.match?(command, ~r/\brun\b/) and
      String.contains?(command, "acceptance/scripts/")
  end

  defp normalize_mode(mode) when is_binary(mode) do
    case String.downcase(mode) do
      "worker" -> :worker_isolated
      "worker_isolated" -> :worker_isolated
      "isolated" -> :worker_isolated
      "serialized" -> :serialized
      _ -> nil
    end
  end

  defp normalize_mode(_mode), do: nil

  defp truthy?(value) when is_binary(value), do: value in @truthy_values
  defp truthy?(_value), do: false

  defp sanitize_segment(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    |> case do
      "" -> "default"
      sanitized -> sanitized
    end
  end
end
