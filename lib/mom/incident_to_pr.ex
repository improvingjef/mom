defmodule Mom.IncidentToPr do
  @moduledoc false

  @ordered_steps [
    incident_detected: :github_issue_created,
    patch_applied: :git_patch_applied,
    tests_passed: :git_tests_run,
    branch_pushed: :git_branch_pushed,
    pr_created: :github_pr_created
  ]

  @type signal :: %{
          success: boolean(),
          missing_steps: [atom()],
          out_of_order_steps: [atom()],
          tests_status_ok: boolean(),
          branch_matches: boolean(),
          branch: String.t() | nil,
          pr_number: integer() | nil
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

    signal = %{
      success:
        missing_steps == [] and out_of_order_steps == [] and tests_status_ok and branch_matches,
      missing_steps: missing_steps,
      out_of_order_steps: out_of_order_steps,
      tests_status_ok: tests_status_ok,
      branch_matches: branch_matches,
      branch: branch,
      pr_number: pr_number(indexed)
    }

    if signal.success, do: {:ok, signal}, else: {:error, signal}
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
