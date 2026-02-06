defmodule Mom.Config do
  @moduledoc false

  @type llm_provider :: :claude_code | :codex | :api_anthropic | :api_openai

  defstruct [
    :repo,
    :node,
    :cookie,
    :mode,
    :llm_provider,
    :llm_cmd,
    :llm_api_key,
    :llm_api_url,
    :llm_model,
    :triage_on_diagnostics,
    :triage_mode,
    :diag_run_queue_mult,
    :diag_mem_high_bytes,
    :diag_cooldown_ms,
    :issue_rate_limit_per_hour,
    :llm_rate_limit_per_hour,
    :issue_dedupe_window_ms,
    :redact_keys,
    :git_ssh_command,
    :open_pr,
    :merge_pr,
    :poll_interval_ms,
    :min_level,
    :dry_run,
    :github_token,
    :github_repo,
    :workdir
  ]

  @type t :: %__MODULE__{
          repo: String.t(),
          node: node() | nil,
          cookie: atom() | nil,
          mode: :remote | :inproc,
          llm_provider: llm_provider(),
          llm_cmd: String.t() | nil,
          llm_api_key: String.t() | nil,
          llm_api_url: String.t() | nil,
          llm_model: String.t() | nil,
          triage_on_diagnostics: boolean(),
          triage_mode: :report | :fix,
          diag_run_queue_mult: pos_integer(),
          diag_mem_high_bytes: pos_integer(),
          diag_cooldown_ms: pos_integer(),
          issue_rate_limit_per_hour: pos_integer(),
          llm_rate_limit_per_hour: pos_integer(),
          issue_dedupe_window_ms: pos_integer(),
          redact_keys: [String.t()],
          git_ssh_command: String.t() | nil,
          open_pr: boolean(),
          merge_pr: boolean(),
          poll_interval_ms: non_neg_integer(),
          min_level: :error | :warning | :info,
          dry_run: boolean(),
          github_token: String.t() | nil,
          github_repo: String.t() | nil,
          workdir: String.t() | nil
        }

  @spec from_opts(keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_opts(opts) do
    repo = Keyword.get(opts, :repo)
    runtime = Application.get_all_env(:mom)
    redact_keys = normalize_redact_keys(Keyword.get(opts, :redact_keys) || runtime[:redact_keys])

    cond do
      is_nil(repo) ->
        {:error, "repo is required"}

      true ->
        {:ok,
         %__MODULE__{
           repo: repo,
           node: Keyword.get(opts, :node),
           cookie: Keyword.get(opts, :cookie),
           mode: Keyword.get(opts, :mode, :remote),
           llm_provider: Keyword.get(opts, :llm_provider, :claude_code),
           llm_cmd: Keyword.get(opts, :llm_cmd) || runtime[:llm_cmd],
           llm_api_key: Keyword.get(opts, :llm_api_key) || runtime[:llm_api_key],
           llm_api_url: Keyword.get(opts, :llm_api_url) || runtime[:llm_api_url],
           llm_model: Keyword.get(opts, :llm_model) || runtime[:llm_model],
           triage_on_diagnostics: Keyword.get(opts, :triage_on_diagnostics, false),
           triage_mode: Keyword.get(opts, :triage_mode, :report),
           diag_run_queue_mult: Keyword.get(opts, :diag_run_queue_mult, 4),
           diag_mem_high_bytes: Keyword.get(opts, :diag_mem_high_bytes, 2 * 1024 * 1024 * 1024),
           diag_cooldown_ms: Keyword.get(opts, :diag_cooldown_ms, 300_000),
           issue_rate_limit_per_hour:
             parse_int(Keyword.get(opts, :issue_rate_limit_per_hour) || runtime[:issue_rate_limit_per_hour]) ||
               60,
           llm_rate_limit_per_hour:
             parse_int(Keyword.get(opts, :llm_rate_limit_per_hour) || runtime[:llm_rate_limit_per_hour]) ||
               60,
           issue_dedupe_window_ms:
             parse_int(Keyword.get(opts, :issue_dedupe_window_ms) || runtime[:issue_dedupe_window_ms]) ||
               3_600_000,
           redact_keys: redact_keys,
           git_ssh_command: Keyword.get(opts, :git_ssh_command) || runtime[:git_ssh_command],
           open_pr: Keyword.get(opts, :open_pr, true),
           merge_pr: Keyword.get(opts, :merge_pr, false),
           poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 5_000),
           min_level: Keyword.get(opts, :min_level, :error),
           dry_run: Keyword.get(opts, :dry_run, false),
           github_token: Keyword.get(opts, :github_token) || runtime[:github_token],
           github_repo: Keyword.get(opts, :github_repo) || runtime[:github_repo],
           workdir: Keyword.get(opts, :workdir)
      }}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp normalize_redact_keys(nil), do: default_redact_keys()
  defp normalize_redact_keys(keys) when is_list(keys), do: Enum.map(keys, &to_string/1)

  defp normalize_redact_keys(keys) when is_binary(keys) do
    keys
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default_redact_keys()
      list -> list
    end
  end

  defp default_redact_keys do
    [
      "password",
      "passwd",
      "secret",
      "token",
      "api_key",
      "apikey",
      "authorization",
      "cookie"
    ]
  end
end
