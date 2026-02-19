# Mom

Mom monitors a running BEAM node for errors, isolates them, attempts a fix, and opens a PR.
It is designed to be minimally intrusive and to run from a separate node when possible.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `mom` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mom, "~> 0.1.0"}
  ]
end
```

## Usage

Run against a target node and repo:

```bash
mix mom /path/to/repo --node app@127.0.0.1 --cookie SECRET \
  --github-repo owner/repo --github-token $GITHUB_TOKEN
```

In-process mode (mom is running inside the same node):

```bash
mix mom /path/to/repo --mode inproc
```

Local stress simulation (rapid synthetic incident generation):

```bash
mix mom.stress --events 200 --max-concurrency 4 --queue-max-size 300 --work-ms 5 --format json
```

## Options

- `--node` Target BEAM node name (`name@host`) for remote mode.
- `--cookie` Cookie for distributed Erlang auth.
- `--mode` `remote` or `inproc`. Default `remote`.
- `--llm` `claude_code`, `codex`, `api_anthropic`, `api_openai`. Default `claude_code`.
- `--llm-cmd` Override CLI command used for the LLM. For `--llm codex`, default is `codex --yolo exec`.
- `--llm-api-key` API key for `api_anthropic` or `api_openai`.
- `--llm-api-url` Override API endpoint for `api_anthropic` or `api_openai`.
- `--llm-model` Override model name for API providers.
- `--triage-on-diagnostics` Enable triage when diagnostics thresholds are exceeded.
- `--triage-mode` `report` or `fix`. Default `report`.
- `--diag-run-queue-mult` Run queue multiplier threshold. Default `4`.
- `--diag-mem-high-bytes` Memory threshold in bytes. Default `2147483648`.
- `--diag-cooldown-ms` Cooldown between triage runs. Default `300000`.
- `--git-ssh-command` Override SSH command for git operations (e.g. specify identity file).
- `--issue-rate-limit-per-hour` Max GitHub issues per hour. Default `60`.
- `--llm-rate-limit-per-hour` Max LLM calls per hour. Default `60`.
- `--issue-dedupe-window-ms` Window for deduping identical issues. Default `3600000`.
- `--redact-keys` Comma-separated list of keys to redact before logging/LLM/issue. Default `password,passwd,secret,token,api_key,apikey,authorization,cookie`.
- `--open-pr` `true` or `false`. Default `true`.
- `--merge-pr` `true` or `false`. Default `false`.
- `--readiness-gate-approved` Explicit approval required before enabling automated PR creation when GitHub credentials + target repo are configured.
- `--poll-interval-ms` Diagnostics polling interval. Default `5000`.
- `--max-concurrency` Max concurrent pipeline jobs. Default `4`.
- `--queue-max-size` Max queued jobs before overflow policy applies. Default `200`.
- `--job-timeout-ms` Per-job timeout budget in milliseconds. Default `120000`.
- `--overflow-policy` `drop_newest` or `drop_oldest`. Default `drop_newest`.
- `--allowed-github-repos` Comma-separated allowlist of permitted `owner/name` repositories for `--github-repo` / `MOM_GITHUB_REPO`.
- `--allowed-actor-ids` Comma-separated allowlist of permitted machine identities for GitHub mutations. Required when `--github-token` is set.
- `--actor-id` Must identify a dedicated machine identity for GitHub-token flows (`[bot]`, `-bot`, `_bot`, or `app/` prefix).
- `--min-level` Minimum logger level to capture. Default `error`.
- `--github-repo` GitHub repo in `owner/name` format.
- `--github-token` Fine-grained PAT or GitHub App token.
- `--workdir` Optional workdir. If not set, a temporary git worktree is used.

## Runtime Config

You can set defaults via environment variables:

- `MOM_GITHUB_TOKEN`
- `MOM_GITHUB_REPO`
- `MOM_LLM_API_KEY`
- `MOM_LLM_API_URL`
- `MOM_LLM_MODEL`
- `MOM_LLM_CMD`
- `MOM_GIT_SSH_COMMAND`
- `MOM_ISSUE_RATE_LIMIT_PER_HOUR`
- `MOM_LLM_RATE_LIMIT_PER_HOUR`
- `MOM_ISSUE_DEDUPE_WINDOW_MS`
- `MOM_MAX_CONCURRENCY`
- `MOM_QUEUE_MAX_SIZE`
- `MOM_JOB_TIMEOUT_MS`
- `MOM_OVERFLOW_POLICY`
- `MOM_ALLOWED_GITHUB_REPOS`
- `MOM_ALLOWED_ACTOR_IDS`
- `MOM_REDACT_KEYS`

## How It Works

1. Connects to a BEAM node and installs a minimal logger handler.
2. Captures error logs and system diagnostics (memory/run queue/reductions).
3. Creates an isolated git worktree to avoid touching production files.
4. Records a GitHub issue for each error/diagnostics anomaly.
5. Requests a patch from a local LLM CLI (Claude Code or Codex).
6. Applies the patch, runs tests, commits, and opens a GitHub PR.

## Security Model

- Uses distributed Erlang cookies for node access.
- Git access is via fine-grained PAT or SSH key, scoped to the repo.
- Default behavior only reads the running system; it never writes to prod.
- Fixes are prepared in a separate git worktree and pushed to a new branch.

## Notes

- API-based LLM providers are stubbed but not yet implemented.
- The PR base branch defaults to `main`.
