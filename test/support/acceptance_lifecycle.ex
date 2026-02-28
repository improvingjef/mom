defmodule Mom.AcceptanceLifecycle do
  @moduledoc """
  Utilities for identifying lingering Playwright-owned `mix run acceptance/scripts/*`
  processes from a process table snapshot, and for deterministic acceptance
  build-artifact isolation controls.
  """

  @type process_row :: %{pid: pos_integer(), ppid: pos_integer(), command: String.t()}
  @type build_artifact_mode :: :worker_isolated | :serialized
  @type retryable_failure :: :monitor_attach_race | :non_retryable
  @type timeout_signal :: :etimedout | :unknown

  @truthy_values ~w(1 true TRUE yes YES on ON)
  @default_acceptance_timeout_ms 120_000
  @runner_burst_script_suffix "acceptance/scripts/runner_burst_acceptance.exs"
  @default_runner_burst_timeout_floor_ms 120_000
  @default_runner_burst_timeout_step_ms 30_000
  @default_runner_burst_timeout_worker_step_ms 5_000
  @default_runner_burst_timeout_cap_ms 300_000
  @default_runner_burst_backoff_base_ms 250
  @default_runner_burst_backoff_step_ms 500
  @default_runner_burst_backoff_worker_step_ms 50
  @default_runner_burst_backoff_cap_ms 5_000
  @default_retry_budget 1
  @default_post_suite_shutdown_timeout_ms 2_000
  @default_timeout_forensics_max_snapshot_rows 200
  @default_timeout_forensics_retention_seconds 86_400
  @monitor_attach_race_markers [
    "missing telemetry failed pipeline event",
    "did not terminate",
    "no process",
    "timeout",
    "etimedout"
  ]
  @ephemeral_build_prefixes [
    "_build_runner_burst_",
    "_build_acceptance_worker_",
    "_build_acceptance_serialized_"
  ]

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

  @spec lingering_mix_run_children_from_samples([String.t() | [process_row()]], pos_integer()) ::
          [process_row()]
  def lingering_mix_run_children_from_samples(samples, root_pid)
      when is_list(samples) and is_integer(root_pid) do
    samples
    |> Enum.flat_map(&lingering_mix_run_children(&1, root_pid))
    |> Enum.uniq_by(& &1.pid)
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

  @spec retry_budget(map()) :: non_neg_integer()
  def retry_budget(env) when is_map(env) do
    env
    |> Map.get("MOM_ACCEPTANCE_RETRY_BUDGET")
    |> parse_non_neg_int(@default_retry_budget)
  end

  @spec fail_on_flaky?(map()) :: boolean()
  def fail_on_flaky?(env) when is_map(env) do
    truthy?(Map.get(env, "MOM_ACCEPTANCE_FAIL_ON_FLAKY"))
  end

  @spec post_suite_shutdown_timeout_ms(map()) :: non_neg_integer()
  def post_suite_shutdown_timeout_ms(env) when is_map(env) do
    env
    |> Map.get("MOM_ACCEPTANCE_POST_SUITE_SHUTDOWN_TIMEOUT_MS")
    |> parse_non_neg_int(@default_post_suite_shutdown_timeout_ms)
  end

  @spec timeout_forensics_max_snapshot_rows(map()) :: non_neg_integer()
  def timeout_forensics_max_snapshot_rows(env) when is_map(env) do
    env
    |> Map.get("MOM_ACCEPTANCE_TIMEOUT_FORENSICS_MAX_SNAPSHOT_ROWS")
    |> parse_non_neg_int(@default_timeout_forensics_max_snapshot_rows)
  end

  @spec timeout_forensics_retention_seconds(map()) :: non_neg_integer()
  def timeout_forensics_retention_seconds(env) when is_map(env) do
    env
    |> Map.get("MOM_ACCEPTANCE_TIMEOUT_FORENSICS_RETENTION_SECONDS")
    |> parse_non_neg_int(@default_timeout_forensics_retention_seconds)
  end

  @spec classify_failure(binary()) :: retryable_failure()
  def classify_failure(message) when is_binary(message) do
    downcased = String.downcase(message)

    if Enum.any?(@monitor_attach_race_markers, &String.contains?(downcased, &1)) do
      :monitor_attach_race
    else
      :non_retryable
    end
  end

  @spec retry?(pos_integer(), non_neg_integer(), retryable_failure()) :: boolean()
  def retry?(attempt, retry_budget, classification)
      when is_integer(attempt) and attempt > 0 and is_integer(retry_budget) and retry_budget >= 0 do
    classification == :monitor_attach_race and attempt <= retry_budget
  end

  @spec acceptance_timeout_ms(binary(), pos_integer(), map(), non_neg_integer()) ::
          non_neg_integer()
  def acceptance_timeout_ms(script_path, attempt, env, base_timeout_ms \\ @default_acceptance_timeout_ms)
      when is_binary(script_path) and is_integer(attempt) and attempt > 0 and is_map(env) and
             is_integer(base_timeout_ms) and base_timeout_ms >= 0 do
    if runner_burst_script?(script_path) do
      timeout_floor_ms =
        parse_non_neg_int(
          Map.get(env, "MOM_ACCEPTANCE_RUNNER_BURST_TIMEOUT_FLOOR_MS"),
          @default_runner_burst_timeout_floor_ms
        )

      timeout_step_ms =
        parse_non_neg_int(
          Map.get(env, "MOM_ACCEPTANCE_RUNNER_BURST_TIMEOUT_STEP_MS"),
          @default_runner_burst_timeout_step_ms
        )

      worker_step_ms =
        parse_non_neg_int(
          Map.get(env, "MOM_ACCEPTANCE_RUNNER_BURST_TIMEOUT_WORKER_STEP_MS"),
          @default_runner_burst_timeout_worker_step_ms
        )

      timeout_cap_ms =
        parse_non_neg_int(
          Map.get(env, "MOM_ACCEPTANCE_RUNNER_BURST_TIMEOUT_CAP_MS"),
          @default_runner_burst_timeout_cap_ms
        )

      worker_index = parse_non_neg_int(Map.get(env, "TEST_WORKER_INDEX"), 0)

      timeout =
        max(base_timeout_ms, timeout_floor_ms) +
          max(attempt - 1, 0) * timeout_step_ms +
          worker_index * worker_step_ms

      min(timeout, timeout_cap_ms)
    else
      base_timeout_ms
    end
  end

  @spec retry_backoff_ms(binary(), pos_integer(), map()) :: non_neg_integer()
  def retry_backoff_ms(script_path, attempt, env)
      when is_binary(script_path) and is_integer(attempt) and attempt > 0 and is_map(env) do
    if runner_burst_script?(script_path) do
      backoff_base_ms =
        parse_non_neg_int(
          Map.get(env, "MOM_ACCEPTANCE_RUNNER_BURST_BACKOFF_BASE_MS"),
          @default_runner_burst_backoff_base_ms
        )

      backoff_step_ms =
        parse_non_neg_int(
          Map.get(env, "MOM_ACCEPTANCE_RUNNER_BURST_BACKOFF_STEP_MS"),
          @default_runner_burst_backoff_step_ms
        )

      backoff_worker_step_ms =
        parse_non_neg_int(
          Map.get(env, "MOM_ACCEPTANCE_RUNNER_BURST_BACKOFF_WORKER_STEP_MS"),
          @default_runner_burst_backoff_worker_step_ms
        )

      backoff_cap_ms =
        parse_non_neg_int(
          Map.get(env, "MOM_ACCEPTANCE_RUNNER_BURST_BACKOFF_CAP_MS"),
          @default_runner_burst_backoff_cap_ms
        )

      worker_index = parse_non_neg_int(Map.get(env, "TEST_WORKER_INDEX"), 0)

      backoff =
        backoff_base_ms +
          max(attempt - 1, 0) * backoff_step_ms +
          worker_index * backoff_worker_step_ms

      min(backoff, backoff_cap_ms)
    else
      0
    end
  end

  @spec timeout_forensics_payload(binary(), pos_integer(), binary(), String.t() | [process_row()]) ::
          %{
            script_path: binary(),
            attempt: pos_integer(),
            classification: retryable_failure(),
            timeout_signal: timeout_signal(),
            process_snapshot: [process_row()]
          }
          | nil
  def timeout_forensics_payload(script_path, attempt, message, snapshot_or_rows) do
    timeout_forensics_payload(script_path, attempt, message, snapshot_or_rows, [])
  end

  @spec timeout_forensics_payload(
          binary(),
          pos_integer(),
          binary(),
          String.t() | [process_row()],
          keyword()
        ) ::
          %{
            script_path: binary(),
            attempt: pos_integer(),
            classification: retryable_failure(),
            timeout_signal: timeout_signal(),
            process_snapshot: [process_row()]
          }
          | nil
  def timeout_forensics_payload(script_path, attempt, message, snapshot_or_rows, opts)
      when is_binary(script_path) and is_integer(attempt) and attempt > 0 and is_binary(message) do
    max_snapshot_rows =
      opts
      |> Keyword.get(:max_snapshot_rows, @default_timeout_forensics_max_snapshot_rows)
      |> normalize_non_neg_int(@default_timeout_forensics_max_snapshot_rows)

    classification = classify_failure(message)
    signal = timeout_signal(message)

    cond do
      not runner_burst_script?(script_path) ->
        nil

      classification != :monitor_attach_race ->
        nil

      signal != :etimedout ->
        nil

      true ->
        process_snapshot =
          case snapshot_or_rows do
            snapshot when is_binary(snapshot) -> parse_snapshot(snapshot)
            rows when is_list(rows) -> Enum.filter(rows, &valid_process_row?/1)
          end
          |> Enum.map(&sanitize_process_row/1)
          |> Enum.take(max_snapshot_rows)

        %{
          script_path: script_path,
          attempt: attempt,
          classification: classification,
          timeout_signal: signal,
          process_snapshot: process_snapshot
        }
    end
  end

  @spec prune_timeout_forensics_entries([map()], keyword()) :: [map()]
  def prune_timeout_forensics_entries(entries, opts \\ []) when is_list(entries) do
    now_seconds = Keyword.get(opts, :now_seconds, System.os_time(:second))

    retention_seconds =
      opts
      |> Keyword.get(:retention_seconds, @default_timeout_forensics_retention_seconds)
      |> normalize_non_neg_int(@default_timeout_forensics_retention_seconds)

    Enum.filter(entries, fn
      %{recorded_at_unix: recorded_at_unix}
      when is_integer(recorded_at_unix) and recorded_at_unix >= 0 and is_integer(now_seconds) ->
        now_seconds - recorded_at_unix <= retention_seconds

      _ ->
        false
    end)
  end

  @spec orphaned_lingering_mix_run_children(String.t() | [process_row()]) :: [process_row()]
  def orphaned_lingering_mix_run_children(snapshot_or_rows) do
    rows =
      case snapshot_or_rows do
        snapshot when is_binary(snapshot) -> parse_snapshot(snapshot)
        rows when is_list(rows) -> rows
      end

    known_pids = MapSet.new(rows, & &1.pid)

    Enum.filter(rows, fn row ->
      lingering_mix_run_command?(row) and row.ppid > 1 and not MapSet.member?(known_pids, row.ppid)
    end)
  end

  @spec orphaned_lingering_mix_run_children_from_samples([String.t() | [process_row()]]) ::
          [process_row()]
  def orphaned_lingering_mix_run_children_from_samples(samples) when is_list(samples) do
    samples
    |> Enum.flat_map(&orphaned_lingering_mix_run_children/1)
    |> Enum.uniq_by(& &1.pid)
  end

  @spec prune_ephemeral_build_artifacts(binary(), keyword()) ::
          {:ok,
           %{
             candidates: non_neg_integer(),
             kept: [binary()],
             removed: [binary()],
             failed: [{binary(), term()}]
           }}
          | {:error, term()}
  def prune_ephemeral_build_artifacts(root_path, opts \\ []) when is_binary(root_path) do
    retention_seconds = Keyword.get(opts, :retention_seconds, 86_400)
    keep_latest = Keyword.get(opts, :keep_latest, 8)
    now_seconds = Keyword.get(opts, :now_seconds, System.os_time(:second))

    with {:ok, entries} <- File.ls(root_path) do
      candidates =
        entries
        |> Enum.flat_map(&ephemeral_candidate(root_path, &1))
        |> Enum.sort_by(& &1.modified_seconds, :desc)

      {kept, removed, failed} =
        candidates
        |> Enum.with_index()
        |> Enum.reduce({[], [], []}, fn {entry, index}, {kept, removed, failed} ->
          keep_by_rank? = index < keep_latest
          within_retention? = now_seconds - entry.modified_seconds <= retention_seconds

          cond do
            keep_by_rank? or within_retention? ->
              {[entry.name | kept], removed, failed}

            true ->
              case File.rm_rf(entry.path) do
                {:ok, _deleted_paths} ->
                  {kept, [entry.name | removed], failed}

                {:error, reason, _path} ->
                  {kept, removed, [{entry.name, reason} | failed]}
              end
          end
        end)

      {:ok,
       %{
         candidates: length(candidates),
         kept: Enum.sort(kept),
         removed: Enum.sort(removed),
         failed: Enum.sort_by(failed, &elem(&1, 0))
       }}
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

  defp sanitize_process_row(%{command: command} = row) when is_binary(command) do
    %{row | command: redact_sensitive_fragments(command)}
  end

  defp sanitize_process_row(row), do: row

  defp redact_sensitive_fragments(command) when is_binary(command) do
    command
    |> redact_env_assignments()
    |> redact_sensitive_equals_flags()
    |> redact_sensitive_space_flags()
    |> redact_bearer_tokens()
  end

  defp redact_env_assignments(command) do
    Regex.replace(
      ~r/\b([A-Za-z_][A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD?|API_KEY|ACCESS_KEY|PRIVATE_KEY|AUTH|AUTHORIZATION|CREDENTIALS?)[A-Za-z0-9_]*)=([^\s]+)/i,
      command,
      "\\1=[REDACTED]"
    )
  end

  defp redact_sensitive_equals_flags(command) do
    Regex.replace(
      ~r/(--?(?:token|api[-_]?key|password|passwd|secret|access[-_]?key|private[-_]?key|auth(?:orization)?|credential(?:s)?))=([^\s]+)/i,
      command,
      "\\1=[REDACTED]"
    )
  end

  defp redact_sensitive_space_flags(command) do
    Regex.replace(
      ~r/(--?(?:token|api[-_]?key|password|passwd|secret|access[-_]?key|private[-_]?key|auth(?:orization)?|credential(?:s)?))\s+([^\s]+)/i,
      command,
      "\\1=[REDACTED]"
    )
  end

  defp redact_bearer_tokens(command) do
    Regex.replace(
      ~r/\b(Bearer)\s+([A-Za-z0-9._\-~+\/]+=*)/i,
      command,
      "\\1 [REDACTED]"
    )
  end

  defp runner_burst_script?(script_path) do
    String.ends_with?(script_path, @runner_burst_script_suffix)
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

  defp parse_non_neg_int(nil, default), do: default

  defp parse_non_neg_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_neg_int(_value, default), do: default

  defp normalize_non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_int(value, default) when is_binary(value), do: parse_non_neg_int(value, default)
  defp normalize_non_neg_int(_value, default), do: default

  defp timeout_signal(message) when is_binary(message) do
    if String.contains?(String.downcase(message), "etimedout"), do: :etimedout, else: :unknown
  end

  defp valid_process_row?(%{pid: pid, ppid: ppid, command: command})
       when is_integer(pid) and pid > 0 and is_integer(ppid) and ppid >= 0 and
              is_binary(command) and command != "",
       do: true

  defp valid_process_row?(_row), do: false

  defp ephemeral_candidate(root_path, entry_name) do
    path = Path.join(root_path, entry_name)

    with true <- Enum.any?(@ephemeral_build_prefixes, &String.starts_with?(entry_name, &1)),
         {:ok, %File.Stat{type: :directory}} <- File.stat(path),
         {:ok, %File.Stat{mtime: modified_seconds}} <- File.stat(path, time: :posix) do
      [%{name: entry_name, path: path, modified_seconds: modified_seconds}]
    else
      _ -> []
    end
  end

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
