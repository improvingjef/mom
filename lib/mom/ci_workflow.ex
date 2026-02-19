defmodule Mom.CIWorkflow do
  @moduledoc false

  @default_workflows_path ".github/workflows"
  @default_playwright_check "ci/playwright"

  @type evidence :: %{
          required_checks: [String.t()],
          workflows_path: String.t(),
          matched_checks: [String.t()],
          playwright_fail_on_flaky: boolean(),
          playwright_concurrency_report_path_set: boolean(),
          playwright_concurrency_artifact_uploaded: boolean()
        }

  @spec verify_required_checks([String.t()], keyword()) ::
          {:ok, evidence()} | {:error, String.t()}
  def verify_required_checks(required_checks, opts \\ [])
      when is_list(required_checks) do
    workflows_path = Keyword.get(opts, :workflows_path, @default_workflows_path)
    playwright_check = Keyword.get(opts, :playwright_check, @default_playwright_check)

    with :ok <- validate_required_checks(required_checks),
         {:ok, workflows} <- load_workflows(workflows_path),
         {:ok, matched_checks} <- ensure_required_checks(required_checks, workflows),
         {:ok, playwright_workflow} <- find_playwright_workflow(playwright_check, workflows),
         :ok <- ensure_playwright_fail_on_flaky(playwright_workflow),
         :ok <- ensure_playwright_concurrency_report_path(playwright_workflow),
         :ok <- ensure_playwright_concurrency_artifact_upload(playwright_workflow) do
      {:ok,
       %{
         required_checks: required_checks,
         workflows_path: workflows_path,
         matched_checks: matched_checks,
         playwright_fail_on_flaky: true,
         playwright_concurrency_report_path_set: true,
         playwright_concurrency_artifact_uploaded: true
       }}
    end
  end

  defp validate_required_checks(required_checks) do
    if Enum.all?(required_checks, &(is_binary(&1) and String.trim(&1) != "")) and
         required_checks != [] do
      :ok
    else
      {:error, "required checks must be a non-empty list of check names"}
    end
  end

  defp load_workflows(workflows_path) do
    files =
      (Path.wildcard(Path.join(workflows_path, "*.yml")) ++
         Path.wildcard(Path.join(workflows_path, "*.yaml")))
      |> Enum.uniq()

    if files == [] do
      {:error, "workflow manifests not found in #{workflows_path}"}
    else
      workflows =
        Enum.map(files, fn file ->
          %{path: file, body: File.read!(file)}
        end)

      {:ok, workflows}
    end
  end

  defp ensure_required_checks(required_checks, workflows) do
    matched =
      Enum.reduce(required_checks, [], fn check, acc ->
        if Enum.any?(workflows, &workflow_declares_check?(&1.body, check)) do
          [check | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    missing = required_checks -- matched

    if missing == [] do
      {:ok, matched}
    else
      {:error,
       "workflow manifests are missing required workflow checks: #{Enum.join(missing, ", ")}"}
    end
  end

  defp find_playwright_workflow(playwright_check, workflows) do
    case Enum.find(workflows, &workflow_declares_check?(&1.body, playwright_check)) do
      nil ->
        {:error, "workflow manifests are missing required workflow checks: #{playwright_check}"}

      workflow ->
        {:ok, workflow}
    end
  end

  defp ensure_playwright_fail_on_flaky(%{body: body}) do
    if Regex.match?(~r/MOM_ACCEPTANCE_FAIL_ON_FLAKY:\s*["']?(?:1|true|yes|on)["']?/i, body) do
      :ok
    else
      {:error, "playwright workflow must set MOM_ACCEPTANCE_FAIL_ON_FLAKY=true"}
    end
  end

  defp ensure_playwright_concurrency_report_path(%{body: body}) do
    if Regex.match?(~r/MOM_ACCEPTANCE_CONCURRENCY_REPORT_PATH:\s*["']?[^"'\n]+["']?/, body) do
      :ok
    else
      {:error, "playwright workflow must set MOM_ACCEPTANCE_CONCURRENCY_REPORT_PATH"}
    end
  end

  defp ensure_playwright_concurrency_artifact_upload(%{body: body}) do
    if Regex.match?(~r/actions\/upload-artifact@/i, body) and
         Regex.match?(~r/concurrency-report/i, body) do
      :ok
    else
      {:error, "playwright workflow must upload a concurrency-report artifact"}
    end
  end

  defp workflow_declares_check?(body, check) do
    escaped = Regex.escape(check)
    Regex.match?(~r/\bname:\s*["']?#{escaped}["']?\s*$/m, body)
  end
end
