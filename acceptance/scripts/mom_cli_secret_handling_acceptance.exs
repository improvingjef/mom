defmodule Mom.Acceptance.MomCliSecretHandlingScript do
  alias Mix.Tasks.Mom, as: MomTask

  def run do
    _ = Application.ensure_all_started(:ex_unit)

    System.put_env("MOM_GITHUB_TOKEN", "env-github-token")
    System.put_env("MOM_GITHUB_CREDENTIAL_SCOPES", "contents,pull_requests,issues")
    System.put_env("MOM_LLM_API_KEY", "env-llm-key")

    {:ok, env_config} =
      MomTask.parse_args([
        "/tmp/repo",
        "--actor-id",
        "mom-app[bot]",
        "--allowed-actor-ids",
        "mom-app[bot]"
      ])

    github_flag_result =
      MomTask.parse_args([
        "/tmp/repo",
        "--github-token",
        "token-from-flag"
      ])

    llm_key_flag_result =
      MomTask.parse_args([
        "/tmp/repo",
        "--llm-api-key",
        "key-from-flag"
      ])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok =
          Mom.Audit.emit(:github_issue_failed, %{
            repo: "acme/mom",
            token: "ghp_123",
            nested: %{authorization: "Bearer abc", cookie: "_session=secret"}
          })
      end)

    result = %{
      github_token_from_env: env_config.github_token,
      llm_api_key_from_env: env_config.llm_api_key,
      github_token_flag_result: normalize(github_flag_result),
      llm_api_key_flag_result: normalize(llm_key_flag_result),
      token_redacted: String.contains?(log, "\"token\":\"[REDACTED]\""),
      authorization_redacted: String.contains?(log, "\"authorization\":\"[REDACTED]\""),
      cookie_redacted: String.contains?(log, "\"cookie\":\"[REDACTED]\""),
      leaked_github_token: String.contains?(log, "ghp_123"),
      leaked_authorization: String.contains?(log, "Bearer abc"),
      leaked_cookie: String.contains?(log, "_session=secret")
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  after
    System.delete_env("MOM_GITHUB_TOKEN")
    System.delete_env("MOM_GITHUB_CREDENTIAL_SCOPES")
    System.delete_env("MOM_LLM_API_KEY")
  end

  defp normalize({:ok, value}), do: ["ok", normalize(value)]
  defp normalize({:error, reason}), do: ["error", to_string(reason)]

  defp normalize(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&normalize/1)
  end

  defp normalize(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {k, normalize(v)} end)
  end

  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_boolean(term), do: term
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.MomCliSecretHandlingScript.run()
