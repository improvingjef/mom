defmodule Mom.HarnessRepo do
  @moduledoc false

  @github_fields "nameWithOwner,isPrivate,url,visibility"

  @type record :: %{
          name_with_owner: String.t(),
          is_private: boolean(),
          url: String.t(),
          visibility: String.t(),
          baseline_error_path: String.t(),
          baseline_diagnostics_path: String.t(),
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

    with {:ok, payload} <- run_gh_view(repo, runner),
         {:ok, record} <- build_record(payload, recorded_at),
         :ok <- validate_scenario_path_arg(:baseline_error_path, baseline_error_path),
         :ok <- validate_scenario_path_arg(:baseline_diagnostics_path, baseline_diagnostics_path),
         :ok <- verify_harness_path(repo, baseline_error_path, runner),
         :ok <- verify_harness_path(repo, baseline_diagnostics_path, runner),
         record <- Map.put(record, :baseline_error_path, baseline_error_path),
         record <- Map.put(record, :baseline_diagnostics_path, baseline_diagnostics_path),
         :ok <- validate_record(record, true),
         :ok <- write_record(record_path, record) do
      {:ok, record}
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
       recorded_at: payload["recorded_at"]
     }}
  end

  defp validate_record(record, baseline_required?) do
    with :ok <- require_field(record, :name_with_owner),
         :ok <- require_field(record, :is_private),
         :ok <- require_field(record, :url),
         :ok <- require_field(record, :visibility),
         :ok <- maybe_require_baseline_field(record, :baseline_error_path, baseline_required?),
         :ok <-
           maybe_require_baseline_field(record, :baseline_diagnostics_path, baseline_required?),
         :ok <- require_field(record, :recorded_at),
         :ok <- validate_private(record),
         :ok <- validate_url(record),
         :ok <- maybe_validate_path(record, :baseline_error_path, baseline_required?),
         :ok <- maybe_validate_path(record, :baseline_diagnostics_path, baseline_required?),
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

  defp validate_path(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_path(_value, field), do: {:error, "harness record has invalid #{field}"}

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
