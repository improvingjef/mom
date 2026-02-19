defmodule Mom.HarnessRepo do
  @moduledoc false

  @github_fields "nameWithOwner,isPrivate,url,visibility"
  @required_capability_ids [
    "pipeline_concurrency",
    "job_timeout_cancellation",
    "inflight_signature_dedupe",
    "pipeline_telemetry_visibility",
    "durable_queue_replay",
    "multi_tenant_fairness",
    "security_allowlist_enforcement",
    "machine_identity_enforcement",
    "egress_policy_fail_closed",
    "observability_slo_alerts"
  ]
  @default_branch_protection_branch "main"
  @default_required_checks ["ci/exunit", "ci/playwright"]
  @default_min_approvals 1
  @default_branch_protection_evidence_path "acceptance/harness_branch_protection_evidence.json"
  @default_ci_workflows_path ".github/workflows"

  @type record :: %{
          name_with_owner: String.t(),
          is_private: boolean(),
          url: String.t(),
          visibility: String.t(),
          baseline_error_path: String.t(),
          baseline_diagnostics_path: String.t(),
          traceability_path: String.t(),
          traceability_mapped_capability_count: pos_integer(),
          branch_protection_branch: String.t(),
          branch_protection_required_checks: [String.t()],
          branch_protection_min_approvals: non_neg_integer(),
          branch_protection_evidence_path: String.t(),
          recorded_at: String.t()
        }

  @spec confirm_and_record(String.t(), String.t(), keyword()) ::
          {:ok, record()} | {:error, String.t()}
  def confirm_and_record(repo, record_path, opts \\ [])
      when is_binary(repo) and is_binary(record_path) do
    runner = Keyword.get(opts, :cmd_runner, &default_cmd_runner/2)
    recorded_at = Keyword.get(opts, :recorded_at, DateTime.utc_now() |> DateTime.to_iso8601())
    baseline_error_path = Keyword.get(opts, :baseline_error_path)
    baseline_diagnostics_path = Keyword.get(opts, :baseline_diagnostics_path)

    traceability_path =
      Keyword.get(opts, :traceability_path, "acceptance/harness_traceability.json")

    branch_protection_branch =
      Keyword.get(opts, :branch_protection_branch, @default_branch_protection_branch)

    required_checks = Keyword.get(opts, :required_checks, @default_required_checks)
    min_approvals = Keyword.get(opts, :min_approvals, @default_min_approvals)
    ci_workflows_path = Keyword.get(opts, :ci_workflows_path, @default_ci_workflows_path)

    branch_protection_evidence_path =
      Keyword.get(
        opts,
        :branch_protection_evidence_path,
        @default_branch_protection_evidence_path
      )

    with {:ok, payload} <- run_gh_view(repo, runner),
         {:ok, record} <- build_record(payload, recorded_at),
         :ok <- validate_scenario_path_arg(:baseline_error_path, baseline_error_path),
         :ok <- validate_scenario_path_arg(:baseline_diagnostics_path, baseline_diagnostics_path),
         :ok <- validate_traceability_path_arg(traceability_path),
         :ok <- validate_branch_protection_branch(branch_protection_branch),
         :ok <- validate_required_checks(required_checks),
         :ok <- validate_min_approvals(min_approvals),
         :ok <- validate_branch_protection_evidence_path(branch_protection_evidence_path),
         :ok <- validate_ci_workflows_path(ci_workflows_path),
         {:ok, ci_workflow_evidence} <-
           Mom.CIWorkflow.verify_required_checks(required_checks,
             workflows_path: ci_workflows_path
           ),
         {:ok, traceability_entries} <- load_traceability(traceability_path),
         :ok <- validate_traceability_entries(traceability_entries),
         :ok <- verify_traceability_paths(repo, traceability_entries, runner),
         :ok <- verify_harness_path(repo, baseline_error_path, runner),
         :ok <- verify_harness_path(repo, baseline_diagnostics_path, runner),
         {:ok, branch_protection_evidence} <-
           verify_branch_protection(
             repo,
             branch_protection_branch,
             required_checks,
             min_approvals,
             runner
           ),
         branch_protection_evidence <-
           Map.put(branch_protection_evidence, :ci_workflow_verification, ci_workflow_evidence),
         :ok <-
           write_branch_protection_evidence(
             branch_protection_evidence_path,
             branch_protection_evidence
           ),
         record <- Map.put(record, :baseline_error_path, baseline_error_path),
         record <- Map.put(record, :baseline_diagnostics_path, baseline_diagnostics_path),
         record <- Map.put(record, :traceability_path, traceability_path),
         record <-
           Map.put(record, :traceability_mapped_capability_count, length(traceability_entries)),
         record <- Map.put(record, :branch_protection_branch, branch_protection_branch),
         record <- Map.put(record, :branch_protection_required_checks, required_checks),
         record <- Map.put(record, :branch_protection_min_approvals, min_approvals),
         record <-
           Map.put(record, :branch_protection_evidence_path, branch_protection_evidence_path),
         :ok <- validate_record(record, true),
         :ok <- write_record(record_path, record) do
      {:ok, record}
    end
  end

  @spec load_traceability(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def load_traceability(traceability_path) when is_binary(traceability_path) do
    with {:ok, body} <- File.read(traceability_path),
         {:ok, payload} <- Jason.decode(body),
         {:ok, entries} <- normalize_traceability(payload) do
      {:ok, entries}
    else
      {:error, :enoent} ->
        {:error, "harness traceability matrix not found at #{traceability_path}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "invalid harness traceability matrix: #{inspect(reason)}"}
    end
  end

  @spec load_record(String.t()) :: {:ok, record()} | {:error, String.t()}
  def load_record(record_path) when is_binary(record_path) do
    with {:ok, body} <- File.read(record_path),
         {:ok, payload} <- Jason.decode(body),
         {:ok, record} <- normalize_record(payload),
         :ok <- validate_record(record, true) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, "harness record not found at #{record_path}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "invalid harness record: #{inspect(reason)}"}
    end
  end

  defp run_gh_view(repo, runner) do
    args = ["repo", "view", repo, "--json", @github_fields]

    case runner.("gh", args) do
      {:ok, output} ->
        Jason.decode(output)

      {:error, reason} ->
        {:error, "failed to query GitHub repo metadata: #{inspect(reason)}"}
    end
  end

  defp build_record(payload, recorded_at) do
    with {:ok, record} <-
           normalize_record(%{
             "name_with_owner" => payload["nameWithOwner"],
             "is_private" => payload["isPrivate"],
             "url" => payload["url"],
             "visibility" => payload["visibility"],
             "recorded_at" => recorded_at
           }),
         :ok <- validate_record(record, false) do
      {:ok, record}
    end
  end

  defp normalize_record(payload) do
    {:ok,
     %{
       name_with_owner: payload["name_with_owner"],
       is_private: payload["is_private"],
       url: payload["url"],
       visibility: payload["visibility"],
       baseline_error_path: payload["baseline_error_path"],
       baseline_diagnostics_path: payload["baseline_diagnostics_path"],
       traceability_path: payload["traceability_path"],
       traceability_mapped_capability_count: payload["traceability_mapped_capability_count"],
       branch_protection_branch: payload["branch_protection_branch"],
       branch_protection_required_checks: payload["branch_protection_required_checks"],
       branch_protection_min_approvals: payload["branch_protection_min_approvals"],
       branch_protection_evidence_path: payload["branch_protection_evidence_path"],
       recorded_at: payload["recorded_at"]
     }}
  end

  defp normalize_traceability(%{"capabilities" => entries}) when is_list(entries) do
    {:ok, entries}
  end

  defp normalize_traceability(_payload) do
    {:error, "harness traceability matrix must contain a capabilities array"}
  end

  defp validate_record(record, baseline_required?) do
    with :ok <- require_field(record, :name_with_owner),
         :ok <- require_field(record, :is_private),
         :ok <- require_field(record, :url),
         :ok <- require_field(record, :visibility),
         :ok <- maybe_require_baseline_field(record, :baseline_error_path, baseline_required?),
         :ok <-
           maybe_require_baseline_field(record, :baseline_diagnostics_path, baseline_required?),
         :ok <- maybe_require_baseline_field(record, :traceability_path, baseline_required?),
         :ok <-
           maybe_require_baseline_field(
             record,
             :traceability_mapped_capability_count,
             baseline_required?
           ),
         :ok <-
           maybe_require_baseline_field(record, :branch_protection_branch, baseline_required?),
         :ok <-
           maybe_require_baseline_field(
             record,
             :branch_protection_required_checks,
             baseline_required?
           ),
         :ok <-
           maybe_require_baseline_field(
             record,
             :branch_protection_min_approvals,
             baseline_required?
           ),
         :ok <-
           maybe_require_baseline_field(
             record,
             :branch_protection_evidence_path,
             baseline_required?
           ),
         :ok <- require_field(record, :recorded_at),
         :ok <- validate_private(record),
         :ok <- validate_url(record),
         :ok <- maybe_validate_path(record, :baseline_error_path, baseline_required?),
         :ok <- maybe_validate_path(record, :baseline_diagnostics_path, baseline_required?),
         :ok <- maybe_validate_path(record, :traceability_path, baseline_required?),
         :ok <- maybe_validate_path(record, :branch_protection_branch, baseline_required?),
         :ok <- maybe_validate_required_checks(record, baseline_required?),
         :ok <- maybe_validate_min_approvals(record, baseline_required?),
         :ok <- maybe_validate_path(record, :branch_protection_evidence_path, baseline_required?),
         :ok <-
           maybe_validate_mapped_count(
             record,
             :traceability_mapped_capability_count,
             baseline_required?
           ),
         :ok <- validate_timestamp(record.recorded_at) do
      :ok
    end
  end

  defp maybe_require_baseline_field(record, field, true), do: require_field(record, field)
  defp maybe_require_baseline_field(_record, _field, false), do: :ok

  defp require_field(record, field) do
    value = Map.get(record, field)

    if is_nil(value) do
      {:error, "harness record is missing required field: #{field}"}
    else
      :ok
    end
  end

  defp validate_private(%{is_private: true}), do: :ok
  defp validate_private(_), do: {:error, "harness repository must be private"}

  defp validate_url(%{name_with_owner: repo, url: url}) do
    prefix = "https://github.com/#{repo}"

    if String.starts_with?(url, prefix) do
      :ok
    else
      {:error, "harness record url must target #{repo}"}
    end
  end

  defp validate_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> :ok
      _ -> {:error, "harness record has invalid recorded_at timestamp"}
    end
  end

  defp validate_scenario_path_arg(key, value) do
    if is_binary(value) and value != "" do
      :ok
    else
      {:error, "missing harness baseline scenario option: #{key}"}
    end
  end

  defp validate_traceability_path_arg(value) do
    if is_binary(value) and value != "" do
      :ok
    else
      {:error, "missing harness traceability option: traceability_path"}
    end
  end

  defp validate_branch_protection_branch(value),
    do: validate_path(value, "branch_protection_branch")

  defp validate_required_checks(value) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) and &1 != "")) and value != [] do
      :ok
    else
      {:error, "harness branch protection required checks must be a non-empty list"}
    end
  end

  defp validate_required_checks(_value) do
    {:error, "harness branch protection required checks must be a non-empty list"}
  end

  defp validate_min_approvals(value) when is_integer(value) and value >= 0, do: :ok

  defp validate_min_approvals(_value) do
    {:error, "harness branch protection min approvals must be a non-negative integer"}
  end

  defp validate_branch_protection_evidence_path(value),
    do: validate_path(value, "branch_protection_evidence_path")

  defp validate_ci_workflows_path(value), do: validate_path(value, "ci_workflows_path")

  defp verify_harness_path(repo, path, runner) do
    args = ["api", "repos/#{repo}/contents/#{path}"]

    case runner.("gh", args) do
      {:ok, _payload} -> :ok
      {:error, _reason} -> {:error, "harness baseline scenario path not found: #{path}"}
    end
  end

  defp maybe_validate_path(record, field, true) do
    validate_path(Map.get(record, field), Atom.to_string(field))
  end

  defp maybe_validate_path(_record, _field, false), do: :ok

  defp maybe_validate_mapped_count(record, field, true) do
    validate_mapped_count(Map.get(record, field), Atom.to_string(field))
  end

  defp maybe_validate_mapped_count(_record, _field, false), do: :ok

  defp maybe_validate_required_checks(record, true) do
    validate_required_checks(Map.get(record, :branch_protection_required_checks))
  end

  defp maybe_validate_required_checks(_record, false), do: :ok

  defp maybe_validate_min_approvals(record, true) do
    validate_min_approvals(Map.get(record, :branch_protection_min_approvals))
  end

  defp maybe_validate_min_approvals(_record, false), do: :ok

  defp validate_path(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_path(_value, field), do: {:error, "harness record has invalid #{field}"}

  defp validate_mapped_count(value, _field) when is_integer(value) and value > 0, do: :ok
  defp validate_mapped_count(_value, field), do: {:error, "harness record has invalid #{field}"}

  defp validate_traceability_entries(entries) when is_list(entries) do
    with :ok <- validate_traceability_entry_shapes(entries),
         :ok <- validate_required_capability_mappings(entries) do
      :ok
    end
  end

  defp validate_traceability_entry_shapes(entries) do
    Enum.reduce_while(entries, :ok, fn entry, _acc ->
      with :ok <- require_traceability_field(entry, "capability_id"),
           :ok <- require_traceability_field(entry, "capability_name"),
           :ok <- require_traceability_field(entry, "scenario_path"),
           :ok <- require_traceability_field(entry, "playwright_spec_path"),
           :ok <- require_traceability_mode(entry["mode"]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_traceability_field(entry, field) do
    value = Map.get(entry, field)

    if is_binary(value) and value != "" do
      :ok
    else
      {:error, "harness traceability entry is missing required field: #{field}"}
    end
  end

  defp require_traceability_mode("baseline"), do: :ok
  defp require_traceability_mode("burst"), do: :ok
  defp require_traceability_mode(_), do: {:error, "harness traceability entry has invalid mode"}

  defp validate_required_capability_mappings(entries) do
    mapped_ids =
      entries
      |> Enum.map(&Map.get(&1, "capability_id"))
      |> MapSet.new()

    missing_ids =
      Enum.reject(@required_capability_ids, fn id ->
        MapSet.member?(mapped_ids, id)
      end)

    if missing_ids == [] do
      :ok
    else
      {:error,
       "harness traceability matrix is missing capability mappings: #{Enum.join(missing_ids, ", ")}"}
    end
  end

  defp verify_traceability_paths(repo, entries, runner) do
    Enum.reduce_while(entries, :ok, fn entry, _acc ->
      with :ok <- verify_harness_path(repo, entry["scenario_path"], runner),
           :ok <- verify_harness_path(repo, entry["playwright_spec_path"], runner) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_branch_protection(repo, branch, required_checks, min_approvals, runner) do
    args = ["api", "repos/#{repo}/branches/#{branch}/protection"]

    with {:ok, payload} <- runner.("gh", args),
         {:ok, decoded} <- Jason.decode(payload),
         observed_checks <- extract_required_status_checks(decoded),
         observed_min_approvals <- extract_required_min_approvals(decoded),
         :ok <- ensure_required_status_checks(required_checks, observed_checks),
         :ok <- ensure_required_min_approvals(min_approvals, observed_min_approvals) do
      {:ok,
       %{
         verified: true,
         repo: repo,
         branch: branch,
         required_checks: required_checks,
         observed_checks: observed_checks,
         required_min_approvals: min_approvals,
         observed_min_approvals: observed_min_approvals,
         verified_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "failed to verify harness branch protection: #{inspect(reason)}"}
    end
  end

  defp extract_required_status_checks(decoded) do
    case get_in(decoded, ["required_status_checks", "contexts"]) do
      contexts when is_list(contexts) ->
        contexts
        |> Enum.filter(&is_binary/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp extract_required_min_approvals(decoded) do
    case get_in(decoded, ["required_pull_request_reviews", "required_approving_review_count"]) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp ensure_required_status_checks(required_checks, observed_checks) do
    observed_set = MapSet.new(observed_checks)

    missing =
      Enum.reject(required_checks, fn check ->
        MapSet.member?(observed_set, check)
      end)

    if missing == [] do
      :ok
    else
      {:error,
       "harness branch protection is missing required status checks: #{Enum.join(missing, ", ")}"}
    end
  end

  defp ensure_required_min_approvals(required, observed) when observed >= required, do: :ok

  defp ensure_required_min_approvals(required, observed) do
    {:error,
     "harness branch protection requires at least #{required} approving review(s); found #{observed}"}
  end

  defp write_branch_protection_evidence(path, evidence) do
    path
    |> Path.dirname()
    |> File.mkdir_p()

    body = Jason.encode_to_iodata!(evidence, pretty: true)

    case File.write(path, body ++ "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "failed to write branch protection evidence: #{inspect(reason)}"}
    end
  end

  defp write_record(record_path, record) do
    record_path
    |> Path.dirname()
    |> File.mkdir_p()

    body = Jason.encode_to_iodata!(record, pretty: true)

    case File.write(record_path, body ++ "\n") do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to write harness record: #{inspect(reason)}"}
    end
  end

  defp default_cmd_runner(cmd, args) do
    {output, status} = System.cmd(cmd, args, stderr_to_stdout: true)

    if status == 0 do
      {:ok, output}
    else
      {:error, String.trim(output)}
    end
  end
end
