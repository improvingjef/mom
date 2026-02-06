defmodule Mix.Tasks.Mom do
  use Mix.Task

  alias Mom.Config

  @shortdoc "Monitor a BEAM node and open PRs for fixes"

  @moduledoc """
  Run Mom against a repo and a target BEAM node.

  Examples:
      mix mom /path/to/repo --node app@127.0.0.1 --cookie SECRET
  """

  @impl true
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [
          node: :string,
          cookie: :string,
          mode: :string,
          llm: :string,
          llm_cmd: :string,
          llm_api_key: :string,
          llm_api_url: :string,
          llm_model: :string,
          triage_on_diagnostics: :boolean,
          triage_mode: :string,
          diag_run_queue_mult: :integer,
          diag_mem_high_bytes: :integer,
          diag_cooldown_ms: :integer,
          git_ssh_command: :string,
          issue_rate_limit_per_hour: :integer,
          llm_rate_limit_per_hour: :integer,
          issue_dedupe_window_ms: :integer,
          redact_keys: :string,
          open_pr: :boolean,
          merge_pr: :boolean,
          poll_interval_ms: :integer,
          min_level: :string,
          dry_run: :boolean,
          github_token: :string,
          github_repo: :string,
          workdir: :string
        ]
      )

    repo =
      case rest do
        [repo | _] -> repo
        _ -> nil
      end

    with {:ok, config} <- build_config(repo, opts),
         {:ok, _pid} <- Mom.start(config) do
      Process.sleep(:infinity)
    else
      {:error, reason} ->
        Mix.raise("mom failed: #{inspect(reason)}")
    end
  end

  defp build_config(repo, opts) do
    opts =
      opts
      |> Keyword.put(:repo, repo)
      |> normalize_opts()

    Config.from_opts(opts)
  end

  defp normalize_opts(opts) do
    mode =
      case Keyword.get(opts, :mode) do
        "inproc" -> :inproc
        "remote" -> :remote
        nil -> :remote
        other -> raise "invalid mode #{other}"
      end

    llm_provider =
      case Keyword.get(opts, :llm) do
        "claude_code" -> :claude_code
        "codex" -> :codex
        "api_anthropic" -> :api_anthropic
        "api_openai" -> :api_openai
        nil -> :claude_code
        other -> raise "invalid llm provider #{other}"
      end

    min_level =
      case Keyword.get(opts, :min_level) do
        "info" -> :info
        "warning" -> :warning
        "error" -> :error
        nil -> :error
        other -> raise "invalid min_level #{other}"
      end

    triage_mode =
      case Keyword.get(opts, :triage_mode) do
        "report" -> :report
        "fix" -> :fix
        nil -> :report
        other -> raise "invalid triage_mode #{other}"
      end

    opts
    |> Keyword.put(:mode, mode)
    |> Keyword.put(:llm_provider, llm_provider)
    |> Keyword.put(:min_level, min_level)
    |> Keyword.put(:triage_mode, triage_mode)
    |> maybe_parse_node()
    |> maybe_parse_cookie()
  end

  defp maybe_parse_node(opts) do
    case Keyword.get(opts, :node) do
      nil -> opts
      node_str -> Keyword.put(opts, :node, String.to_atom(node_str))
    end
  end

  defp maybe_parse_cookie(opts) do
    case Keyword.get(opts, :cookie) do
      nil -> opts
      cookie -> Keyword.put(opts, :cookie, String.to_atom(cookie))
    end
  end
end
