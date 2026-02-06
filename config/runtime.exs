import Config

if config_env() in [:dev, :prod] do
  config :mom,
    github_token: System.get_env("MOM_GITHUB_TOKEN"),
    github_repo: System.get_env("MOM_GITHUB_REPO"),
    llm_api_key: System.get_env("MOM_LLM_API_KEY"),
    llm_api_url: System.get_env("MOM_LLM_API_URL"),
    llm_model: System.get_env("MOM_LLM_MODEL"),
    llm_cmd: System.get_env("MOM_LLM_CMD"),
    git_ssh_command: System.get_env("MOM_GIT_SSH_COMMAND"),
    issue_rate_limit_per_hour: System.get_env("MOM_ISSUE_RATE_LIMIT_PER_HOUR"),
    llm_rate_limit_per_hour: System.get_env("MOM_LLM_RATE_LIMIT_PER_HOUR"),
    issue_dedupe_window_ms: System.get_env("MOM_ISSUE_DEDUPE_WINDOW_MS"),
    redact_keys: System.get_env("MOM_REDACT_KEYS")
end
