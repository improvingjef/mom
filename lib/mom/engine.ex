defmodule Mom.Engine do
  @moduledoc false

  alias Mom.{Config, Git, Isolation, LLM, GitHub, RateLimiter, Security}

  require Logger

  @spec handle_log(map(), Config.t()) :: :ok
  def handle_log(event, %Config{} = config) do
    Logger.info("mom: triaging error")

    sanitized_event = Security.sanitize(event, config.redact_keys)
    _ = record_issue_for_error(sanitized_event, config)

    with {:ok, workdir} <- Isolation.prepare_workdir(config),
         {:ok, context} <- build_context(sanitized_event, config, workdir),
         {:ok, patch} <- LLM.generate_patch(context, config),
         :ok <- Git.apply_patch(workdir, patch),
         :ok <- ensure_test_patch(event, config, workdir),
         :ok <- Git.run_tests(workdir),
         {:ok, branch} <- Git.commit_changes(workdir, "mom: fix error"),
         {:ok, pr} <- maybe_open_pr(workdir, branch, config),
         :ok <- maybe_merge(pr, config) do
      Logger.info("mom: fix prepared #{inspect(pr)}")
      :ok
    else
      {:error, reason} ->
        Logger.error("mom: fix failed #{inspect(reason)}")
        :ok
    end
  end

  @spec handle_diagnostics(map(), list(), Config.t()) :: :ok
  def handle_diagnostics(report, issues, %Config{triage_mode: :report} = config) do
    sanitized_report = Security.sanitize(report, config.redact_keys)
    sanitized_issues = Security.sanitize(issues, config.redact_keys)
    _ = record_issue_for_diagnostics(sanitized_report, sanitized_issues, config)

    context = %{
      repo: config.repo,
      report: sanitized_report,
      issues: sanitized_issues,
      hot_processes: fetch_hot_processes(config),
      instructions:
        "Provide a concise diagnosis summary and suggested next steps. Do not include a diff."
    }

    case LLM.generate_text(context, config) do
      {:ok, text} -> Logger.warning("mom: diagnostics triage report\n#{text}")
      {:error, reason} -> Logger.error("mom: diagnostics triage failed #{inspect(reason)}")
    end

    :ok
  end

  def handle_diagnostics(report, issues, %Config{triage_mode: :fix} = config) do
    sanitized_report = Security.sanitize(report, config.redact_keys)
    sanitized_issues = Security.sanitize(issues, config.redact_keys)
    _ = record_issue_for_diagnostics(sanitized_report, sanitized_issues, config)

    context = %{
      repo: config.repo,
      report: sanitized_report,
      issues: sanitized_issues,
      hot_processes: fetch_hot_processes(config),
      instructions:
        "Propose a minimal fix or mitigation and add a regression test if applicable. Return a unified diff only."
    }

    case LLM.generate_patch(context, config) do
      {:ok, patch} ->
        with {:ok, workdir} <- Isolation.prepare_workdir(config),
             :ok <- Git.apply_patch(workdir, patch),
             :ok <- ensure_test_patch(%{diagnostics: report, issues: issues}, config, workdir),
             :ok <- Git.run_tests(workdir),
             {:ok, branch} <- Git.commit_changes(workdir, "mom: diagnostics fix"),
             {:ok, pr} <- maybe_open_pr(workdir, branch, config),
             :ok <- maybe_merge(pr, config) do
          Logger.info("mom: diagnostics fix prepared #{inspect(pr)}")
          :ok
        else
          {:error, reason} ->
            Logger.error("mom: diagnostics fix failed #{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.error("mom: diagnostics fix failed #{inspect(reason)}")
        :ok
    end
  end

  defp build_context(event, %Config{repo: repo} = _config, workdir) do
    {:ok,
     %{
       repo: repo,
       workdir: workdir,
       event: event,
         instructions:
         "Create a minimal regression test and propose a patch. Return a unified diff only."
     }}
  end

  defp fetch_hot_processes(%Config{mode: :inproc}) do
    Mom.Diagnostics.hot_processes()
  end

  defp fetch_hot_processes(%Config{mode: :remote, node: node}) do
    :rpc.call(node, Mom.Diagnostics, :hot_processes, [])
  end

  defp ensure_test_patch(event, config, workdir) do
    case Git.touches_tests?(workdir) do
      true ->
        :ok

      false ->
        context = %{
          repo: config.repo,
          workdir: workdir,
          event: Security.sanitize(event, config.redact_keys),
          instructions:
            "Add a minimal ExUnit regression test for the error. Return a unified diff only."
        }

        with {:ok, patch} <- LLM.generate_patch(context, config),
             :ok <- Git.apply_patch(workdir, patch) do
          :ok
        end
    end
  end

  defp maybe_open_pr(_workdir, _branch, %Config{open_pr: false}), do: {:ok, nil}

  defp maybe_open_pr(workdir, branch, %Config{} = config) do
    with :ok <- Git.push_branch(workdir, branch),
         {:ok, pr} <- GitHub.create_pr(config, branch) do
      {:ok, pr}
    end
  end

  defp maybe_merge(_pr, %Config{merge_pr: false}), do: :ok
  defp maybe_merge(nil, _config), do: :ok
  defp maybe_merge(pr, %Config{} = config), do: GitHub.merge_pr(config, pr)

  defp record_issue_for_error(event, %Config{} = config) do
    title = "mom: production error detected"
    body = """
    Mom detected an error event.

    ```
    #{inspect(event, pretty: true, limit: :infinity)}
    ```
    """

    signature = Security.signature(event)
    maybe_create_issue(config, title, body, signature)
  end

  defp record_issue_for_diagnostics(report, issues, %Config{} = config) do
    title = "mom: diagnostics threshold exceeded"
    body = """
    Mom detected a diagnostics anomaly.

    Issues:
    ```
    #{inspect(issues, pretty: true, limit: :infinity)}
    ```

    Report:
    ```
    #{inspect(report, pretty: true, limit: :infinity)}
    ```
    """

    signature = Security.signature({report, issues})
    maybe_create_issue(config, title, body, signature)
  end

  defp maybe_create_issue(%Config{github_token: nil}, _title, _body, _sig), do: :ok
  defp maybe_create_issue(%Config{github_repo: nil}, _title, _body, _sig), do: :ok

  defp maybe_create_issue(%Config{} = config, title, body, signature) do
    allowed? =
      RateLimiter.allow?(:issue, config.issue_rate_limit_per_hour, 3_600_000) and
        RateLimiter.allow_issue_signature?(signature, config.issue_dedupe_window_ms)

    if not allowed? do
      Logger.warning("mom: issue creation skipped (rate limit or dedupe)")
      :ok
    else
      case GitHub.create_issue(config, title, body) do
      {:ok, issue} ->
        Logger.info("mom: issue created #{inspect(issue)}")
        :ok

      {:error, reason} ->
        Logger.error("mom: issue creation failed #{inspect(reason)}")
        :ok
      end
    end
  end
end
