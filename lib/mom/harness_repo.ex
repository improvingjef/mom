defmodule Mom.HarnessRepo do
  @moduledoc false

  @github_fields "nameWithOwner,isPrivate,url,visibility"

  @type record :: %{
          name_with_owner: String.t(),
          is_private: boolean(),
          url: String.t(),
          visibility: String.t(),
          recorded_at: String.t()
        }

  @spec confirm_and_record(String.t(), String.t(), keyword()) ::
          {:ok, record()} | {:error, String.t()}
  def confirm_and_record(repo, record_path, opts \\ [])
      when is_binary(repo) and is_binary(record_path) do
    runner = Keyword.get(opts, :cmd_runner, &default_cmd_runner/2)
    recorded_at = Keyword.get(opts, :recorded_at, DateTime.utc_now() |> DateTime.to_iso8601())

    with {:ok, payload} <- run_gh_view(repo, runner),
         {:ok, record} <- build_record(payload, recorded_at),
         :ok <- write_record(record_path, record) do
      {:ok, record}
    end
  end

  @spec load_record(String.t()) :: {:ok, record()} | {:error, String.t()}
  def load_record(record_path) when is_binary(record_path) do
    with {:ok, body} <- File.read(record_path),
         {:ok, payload} <- Jason.decode(body),
         {:ok, record} <- normalize_record(payload),
         :ok <- validate_record(record) do
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
         :ok <- validate_record(record) do
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
       recorded_at: payload["recorded_at"]
     }}
  end

  defp validate_record(record) do
    with :ok <- require_field(record, :name_with_owner),
         :ok <- require_field(record, :is_private),
         :ok <- require_field(record, :url),
         :ok <- require_field(record, :visibility),
         :ok <- require_field(record, :recorded_at),
         :ok <- validate_private(record),
         :ok <- validate_url(record),
         :ok <- validate_timestamp(record.recorded_at) do
      :ok
    end
  end

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
