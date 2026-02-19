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
    :max_concurrency,
    :queue_max_size,
    :job_timeout_ms,
    :overflow_policy,
    :allowed_github_repos,
    :allowed_actor_ids,
    :branch_name_prefix,
    :min_level,
    :dry_run,
    :github_token,
    :github_repo,
    :github_base_branch,
    :protected_branches,
    :actor_id,
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
          max_concurrency: non_neg_integer(),
          queue_max_size: pos_integer(),
          job_timeout_ms: pos_integer(),
          overflow_policy: :drop_newest | :drop_oldest,
          allowed_github_repos: [String.t()],
          allowed_actor_ids: [String.t()],
          branch_name_prefix: String.t(),
          min_level: :error | :warning | :info,
          dry_run: boolean(),
          github_token: String.t() | nil,
          github_repo: String.t() | nil,
          github_base_branch: String.t(),
          protected_branches: [String.t()],
          actor_id: String.t(),
          workdir: String.t() | nil
        }

  @spec from_opts(keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_opts(opts) do
    repo = Keyword.get(opts, :repo)
    runtime = Application.get_all_env(:mom)
    redact_keys = normalize_redact_keys(Keyword.get(opts, :redact_keys) || runtime[:redact_keys])
    llm_provider = Keyword.get(opts, :llm_provider, :claude_code)
    llm_cmd = default_llm_cmd(llm_provider, Keyword.get(opts, :llm_cmd) || runtime[:llm_cmd])

    cond do
      is_nil(repo) ->
        {:error, "repo is required"}

      true ->
        github_token = Keyword.get(opts, :github_token) || runtime[:github_token]
        actor_id = parse_actor_id(opts, runtime)

        with {:ok, max_concurrency} <- parse_non_neg_int(opts, runtime, :max_concurrency, 4),
             {:ok, queue_max_size} <- parse_pos_int(opts, runtime, :queue_max_size, 200),
             {:ok, job_timeout_ms} <- parse_pos_int(opts, runtime, :job_timeout_ms, 120_000),
             {:ok, overflow_policy} <- parse_overflow_policy(opts, runtime),
             {:ok, allowed_github_repos} <- parse_allowed_github_repos(opts, runtime),
             {:ok, allowed_actor_ids} <- parse_allowed_actor_ids(opts, runtime),
             {:ok, branch_name_prefix} <- parse_branch_name_prefix(opts, runtime),
             {:ok, github_base_branch} <- parse_github_base_branch(opts, runtime),
             {:ok, protected_branches} <-
               parse_protected_branches(opts, runtime, github_base_branch),
             :ok <- validate_actor_identity(actor_id, github_token, allowed_actor_ids),
             {:ok, github_repo} <-
               parse_and_validate_github_repo(opts, runtime, allowed_github_repos) do
          {:ok,
           %__MODULE__{
             repo: repo,
             node: Keyword.get(opts, :node),
             cookie: Keyword.get(opts, :cookie),
             mode: Keyword.get(opts, :mode, :remote),
             llm_provider: llm_provider,
             llm_cmd: llm_cmd,
             llm_api_key: Keyword.get(opts, :llm_api_key) || runtime[:llm_api_key],
             llm_api_url: Keyword.get(opts, :llm_api_url) || runtime[:llm_api_url],
             llm_model: Keyword.get(opts, :llm_model) || runtime[:llm_model],
             triage_on_diagnostics: Keyword.get(opts, :triage_on_diagnostics, false),
             triage_mode: Keyword.get(opts, :triage_mode, :report),
             diag_run_queue_mult: Keyword.get(opts, :diag_run_queue_mult, 4),
             diag_mem_high_bytes: Keyword.get(opts, :diag_mem_high_bytes, 2 * 1024 * 1024 * 1024),
             diag_cooldown_ms: Keyword.get(opts, :diag_cooldown_ms, 300_000),
             issue_rate_limit_per_hour:
               parse_int(
                 Keyword.get(opts, :issue_rate_limit_per_hour) ||
                   runtime[:issue_rate_limit_per_hour]
               ) ||
                 60,
             llm_rate_limit_per_hour:
               parse_int(
                 Keyword.get(opts, :llm_rate_limit_per_hour) || runtime[:llm_rate_limit_per_hour]
               ) ||
                 60,
             issue_dedupe_window_ms:
               parse_int(
                 Keyword.get(opts, :issue_dedupe_window_ms) || runtime[:issue_dedupe_window_ms]
               ) ||
                 3_600_000,
             redact_keys: redact_keys,
             git_ssh_command: Keyword.get(opts, :git_ssh_command) || runtime[:git_ssh_command],
             open_pr: Keyword.get(opts, :open_pr, true),
             merge_pr: Keyword.get(opts, :merge_pr, false),
             poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 5_000),
             max_concurrency: max_concurrency,
             queue_max_size: queue_max_size,
             job_timeout_ms: job_timeout_ms,
             overflow_policy: overflow_policy,
             allowed_github_repos: allowed_github_repos,
             allowed_actor_ids: allowed_actor_ids,
             branch_name_prefix: branch_name_prefix,
             min_level: Keyword.get(opts, :min_level, :error),
             dry_run: Keyword.get(opts, :dry_run, false),
             github_token: github_token,
             github_repo: github_repo,
             github_base_branch: github_base_branch,
             protected_branches: protected_branches,
             actor_id: actor_id,
             workdir: Keyword.get(opts, :workdir)
           }}
        end
    end
  end

  defp default_llm_cmd(:codex, nil), do: "codex --yolo exec"
  defp default_llm_cmd(_provider, cmd), do: cmd

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

  defp parse_allowed_github_repos(opts, runtime) do
    value = Keyword.get(opts, :allowed_github_repos, runtime[:allowed_github_repos])
    {:ok, normalize_allowed_repos(value)}
  end

  defp parse_allowed_actor_ids(opts, runtime) do
    value = Keyword.get(opts, :allowed_actor_ids, runtime[:allowed_actor_ids])
    {:ok, normalize_allowed_repos(value)}
  end

  defp normalize_allowed_repos(nil), do: []
  defp normalize_allowed_repos([]), do: []

  defp normalize_allowed_repos(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_allowed_repos(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_allowed_repos(_), do: []

  defp parse_non_neg_int(opts, runtime, key, default) do
    value = Keyword.get(opts, key, runtime[key])

    case parse_int(value) do
      nil -> {:ok, default}
      parsed when parsed >= 0 -> {:ok, parsed}
      _parsed -> {:error, "#{key} must be a non-negative integer"}
    end
  end

  defp parse_pos_int(opts, runtime, key, default) do
    value = Keyword.get(opts, key, runtime[key])

    case parse_int(value) do
      nil -> {:ok, default}
      parsed when parsed > 0 -> {:ok, parsed}
      _parsed -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp parse_overflow_policy(opts, runtime) do
    case Keyword.get(opts, :overflow_policy, runtime[:overflow_policy]) do
      nil -> {:ok, :drop_newest}
      :drop_newest -> {:ok, :drop_newest}
      :drop_oldest -> {:ok, :drop_oldest}
      "drop_newest" -> {:ok, :drop_newest}
      "drop_oldest" -> {:ok, :drop_oldest}
      _other -> {:error, "overflow_policy must be :drop_newest or :drop_oldest"}
    end
  end

  defp parse_and_validate_github_repo(opts, runtime, allowed_github_repos) do
    github_repo = Keyword.get(opts, :github_repo) || runtime[:github_repo]

    cond do
      allowed_github_repos == [] ->
        {:ok, github_repo}

      is_nil(github_repo) ->
        {:error, "github_repo must be set when allowed_github_repos is configured"}

      github_repo in allowed_github_repos ->
        {:ok, github_repo}

      true ->
        {:error, "github_repo is not allowed"}
    end
  end

  defp parse_branch_name_prefix(opts, runtime) do
    prefix = Keyword.get(opts, :branch_name_prefix, runtime[:branch_name_prefix]) || "mom"

    if valid_branch_prefix?(prefix) do
      {:ok, prefix}
    else
      {:error, "branch_name_prefix is not a valid git branch prefix"}
    end
  end

  defp parse_github_base_branch(opts, runtime) do
    base_branch = Keyword.get(opts, :github_base_branch, runtime[:github_base_branch]) || "main"

    if valid_branch_prefix?(base_branch) do
      {:ok, base_branch}
    else
      {:error, "github_base_branch is not a valid git branch name"}
    end
  end

  defp parse_protected_branches(opts, runtime, github_base_branch) do
    parsed =
      opts
      |> Keyword.get(:protected_branches, runtime[:protected_branches])
      |> normalize_allowed_repos()
      |> case do
        [] -> [github_base_branch]
        list -> list
      end
      |> Enum.uniq()

    if Enum.all?(parsed, &valid_branch_prefix?/1) do
      {:ok, parsed}
    else
      {:error, "protected_branches must contain valid git branch names"}
    end
  end

  defp valid_branch_prefix?(prefix) when is_binary(prefix) do
    trimmed = String.trim(prefix)

    trimmed == prefix and
      trimmed != "" and
      Regex.match?(~r/^[0-9A-Za-z._\/-]+$/, trimmed) and
      not String.contains?(trimmed, ["..", "@{"]) and
      not String.starts_with?(trimmed, ["/", ".", "-"]) and
      not String.ends_with?(trimmed, ["/", ".", ".lock"]) and
      Enum.all?(String.split(trimmed, "/"), &valid_branch_segment?/1)
  end

  defp valid_branch_prefix?(_), do: false

  defp valid_branch_segment?(segment) do
    segment != "" and
      segment != "." and
      segment != ".." and
      not String.starts_with?(segment, ".") and
      not String.ends_with?(segment, ".lock")
  end

  defp parse_actor_id(opts, runtime) do
    case Keyword.get(opts, :actor_id) || runtime[:actor_id] || System.get_env("GITHUB_ACTOR") do
      nil -> "mom"
      actor when is_binary(actor) -> String.trim(actor)
      actor -> to_string(actor) |> String.trim()
    end
  end

  defp validate_actor_identity(actor_id, github_token, allowed_actor_ids) do
    cond do
      actor_id == "" ->
        {:error, "actor_id must not be empty"}

      is_binary(github_token) and String.trim(github_token) != "" and allowed_actor_ids == [] ->
        {:error, "allowed_actor_ids must be set when github_token is configured"}

      allowed_actor_ids != [] and actor_id not in allowed_actor_ids ->
        {:error, "actor_id is not allowed"}

      is_binary(github_token) and String.trim(github_token) != "" and
          not machine_actor_identity?(actor_id) ->
        {:error, "actor_id must be a dedicated machine identity"}

      true ->
        :ok
    end
  end

  defp machine_actor_identity?(actor_id) when is_binary(actor_id) do
    normalized = String.downcase(actor_id)

    String.ends_with?(normalized, "[bot]") or
      String.contains?(normalized, "-bot") or
      String.contains?(normalized, "_bot") or
      String.starts_with?(normalized, "app/")
  end

  defp machine_actor_identity?(_), do: false
end
