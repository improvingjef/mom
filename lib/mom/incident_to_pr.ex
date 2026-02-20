defmodule Mom.IncidentToPr do
  @moduledoc false

  @ordered_steps [
    incident_detected: :github_issue_created,
    patch_applied: :git_patch_applied,
    tests_passed: :git_tests_run,
    branch_pushed: :git_branch_pushed,
    pr_created: :github_pr_created
  ]

  @stop_point_steps [
    detect: :incident_detected,
    patch_apply: :patch_applied,
    tests: :tests_passed,
    push: :branch_pushed,
    pr_create: :pr_created
  ]

  @failure_events %{
    detect: :github_issue_failed,
    patch_apply: :git_patch_failed,
    push: :git_branch_push_failed,
    pr_create: :github_pr_failed
  }

  @type signal :: %{
          success: boolean(),
          missing_steps: [atom()],
          out_of_order_steps: [atom()],
          tests_status_ok: boolean(),
          branch_matches: boolean(),
          branch: String.t() | nil,
          pr_number: integer() | nil,
          stop_point_classification: %{
            detect: :passed | :failed | :missing | :out_of_order,
            patch_apply: :passed | :failed | :missing | :out_of_order,
            tests: :passed | :failed | :missing | :out_of_order,
            push: :passed | :failed | :missing | :out_of_order,
            pr_create: :passed | :failed | :missing | :out_of_order
          },
          failure_stop_point: :detect | :patch_apply | :tests | :push | :pr_create | nil
        }

  @spec evaluate([tuple()]) :: {:ok, signal()} | {:error, signal()}
  def evaluate(events) when is_list(events) do
    indexed = events |> normalize_events() |> Enum.with_index()

    step_indexes =
      Map.new(@ordered_steps, fn {step, event_name} ->
        {step, first_event_index(indexed, event_name)}
      end)

    missing_steps =
      step_indexes
      |> Enum.filter(fn {_step, index} -> is_nil(index) end)
      |> Enum.map(fn {step, _index} -> step end)

    out_of_order_steps = out_of_order_steps(step_indexes)

    tests_status_ok = tests_status_ok?(indexed)
    branch = branch_for(indexed, :git_branch_pushed)
    pr_branch = branch_for(indexed, :github_pr_created)
    branch_matches = is_binary(branch) and is_binary(pr_branch) and branch == pr_branch
    stop_point_classification =
      stop_point_classification(indexed, step_indexes, out_of_order_steps, tests_status_ok)

    signal = %{
      success:
        missing_steps == [] and out_of_order_steps == [] and tests_status_ok and branch_matches,
      missing_steps: missing_steps,
      out_of_order_steps: out_of_order_steps,
      tests_status_ok: tests_status_ok,
      branch_matches: branch_matches,
      branch: branch,
      pr_number: pr_number(indexed),
      stop_point_classification: stop_point_classification,
      failure_stop_point: first_failure_stop_point(stop_point_classification)
    }

    if signal.success, do: {:ok, signal}, else: {:error, signal}
  end

  @spec persist_summary_artifact(signal(), keyword()) ::
          {:ok, String.t()}
          | {:error, :artifact_dir_not_configured | :invalid_run_id | :already_exists | term()}
  def persist_summary_artifact(signal, opts \\ []) when is_map(signal) and is_list(opts) do
    with {:ok, artifact_dir} <- artifact_dir(opts),
         {:ok, run_id} <- normalize_run_id(Keyword.get(opts, :run_id)),
         :ok <- File.mkdir_p(artifact_dir),
         path <- Path.join(artifact_dir, "#{run_id}.json"),
         payload <- summary_payload(signal, run_id),
         encoded <- Jason.encode!(payload),
         :ok <- write_immutable(path, encoded) do
      {:ok, path}
    end
  end

  defp normalize_events(events) do
    Enum.flat_map(events, fn
      {[:mom, :audit, event_name], metadata} when is_atom(event_name) and is_map(metadata) ->
        [{event_name, metadata}]

      {event_name, metadata} when is_atom(event_name) and is_map(metadata) ->
        [{event_name, metadata}]

      _other ->
        []
    end)
  end

  defp artifact_dir(opts) do
    case Keyword.get(opts, :artifact_dir) || Application.get_env(:mom, :incident_to_pr_artifact_dir) do
      path when is_binary(path) ->
        trimmed = String.trim(path)
        if trimmed == "", do: {:error, :artifact_dir_not_configured}, else: {:ok, trimmed}

      _other ->
        {:error, :artifact_dir_not_configured}
    end
  end

  defp normalize_run_id(run_id) when is_binary(run_id) do
    sanitized =
      run_id
      |> String.trim()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

    if sanitized == "", do: {:error, :invalid_run_id}, else: {:ok, sanitized}
  end

  defp normalize_run_id(_run_id), do: {:error, :invalid_run_id}

  defp summary_payload(signal, run_id) do
    %{
      run_id: run_id,
      recorded_at_unix: DateTime.utc_now() |> DateTime.to_unix(),
      signal: signal
    }
  end

  defp write_immutable(path, encoded) do
    case File.write(path, encoded <> "\n", [:write, :exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_event_index(indexed_events, event_name) do
    case Enum.find(indexed_events, fn {{name, _metadata}, _index} -> name == event_name end) do
      {_event, index} -> index
      nil -> nil
    end
  end

  defp out_of_order_steps(step_indexes) do
    @ordered_steps
    |> Enum.map(fn {step, _event_name} -> {step, Map.get(step_indexes, step)} end)
    |> Enum.reduce({nil, []}, fn
      {_step, nil}, {last_seen, acc} ->
        {last_seen, acc}

      {_step, index}, {nil, acc} ->
        {index, acc}

      {step, index}, {last_seen, acc} when index < last_seen ->
        {last_seen, [step | acc]}

      {_step, index}, {_last_seen, acc} ->
        {index, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp tests_status_ok?(indexed_events) do
    case Enum.find(indexed_events, fn {{event_name, _metadata}, _index} ->
           event_name == :git_tests_run
         end) do
      {{:git_tests_run, metadata}, _index} ->
        status = fetch_field(metadata, :status)
        status == "ok"

      nil ->
        false
    end
  end

  defp stop_point_classification(indexed, step_indexes, out_of_order_steps, tests_status_ok) do
    Map.new(@stop_point_steps, fn {stop_point, step} ->
      classification =
        cond do
          step in out_of_order_steps ->
            :out_of_order

          stop_point == :tests and Map.get(step_indexes, step) == nil ->
            :missing

          stop_point == :tests and tests_status_ok ->
            :passed

          stop_point == :tests ->
            :failed

          Map.get(step_indexes, step) != nil ->
            :passed

          failed_event?(indexed, Map.get(@failure_events, stop_point)) ->
            :failed

          true ->
            :missing
        end

      {stop_point, classification}
    end)
  end

  defp first_failure_stop_point(classifications) do
    Enum.find_value(@stop_point_steps, fn {stop_point, _step} ->
      case Map.get(classifications, stop_point) do
        :passed -> nil
        _failure -> stop_point
      end
    end)
  end

  defp failed_event?(_indexed, nil), do: false

  defp failed_event?(indexed, event_name) do
    Enum.any?(indexed, fn {{name, _metadata}, _index} -> name == event_name end)
  end

  defp branch_for(indexed_events, event_name) do
    case Enum.find(indexed_events, fn {{name, _metadata}, _index} -> name == event_name end) do
      {{_name, metadata}, _index} -> fetch_field(metadata, :branch)
      nil -> nil
    end
  end

  defp pr_number(indexed_events) do
    case Enum.find(indexed_events, fn {{name, _metadata}, _index} ->
           name == :github_pr_created
         end) do
      {{:github_pr_created, metadata}, _index} ->
        fetch_field(metadata, :pr_number)

      nil ->
        nil
    end
  end

  defp fetch_field(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end
end
