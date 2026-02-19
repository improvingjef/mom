defmodule Mom.AcceptanceLifecycle do
  @moduledoc """
  Utilities for identifying lingering Playwright-owned `mix run acceptance/scripts/*`
  processes from a process table snapshot.
  """

  @type process_row :: %{pid: pos_integer(), ppid: pos_integer(), command: String.t()}

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
end
