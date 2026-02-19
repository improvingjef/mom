defmodule Mom.Acceptance.MomCliGitHubScopeVerificationScript do
  def run do
    System.put_env("MOM_GITHUB_TOKEN", "token")
    System.delete_env("MOM_GITHUB_CREDENTIAL_SCOPES")

    missing_scopes_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "acme/mom",
        "--actor-id",
        "mom-app[bot]",
        "--allowed-actor-ids",
        "mom-app[bot]",
        "--readiness-gate-approved"
      ])

    insufficient_scopes_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "acme/mom",
        "--actor-id",
        "mom-app[bot]",
        "--allowed-actor-ids",
        "mom-app[bot]",
        "--github-credential-scopes",
        "contents,issues",
        "--readiness-gate-approved"
      ])

    passing_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "acme/mom",
        "--actor-id",
        "mom-app[bot]",
        "--allowed-actor-ids",
        "mom-app[bot]",
        "--github-credential-scopes",
        "contents,pull_requests,issues",
        "--readiness-gate-approved"
      ])

    result = %{
      missing_scopes_result: missing_scopes_result,
      insufficient_scopes_result: insufficient_scopes_result,
      parsed_scopes: parsed_scopes(passing_result)
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  after
    System.delete_env("MOM_GITHUB_TOKEN")
    System.delete_env("MOM_GITHUB_CREDENTIAL_SCOPES")
  end

  defp parsed_scopes({:ok, config}), do: config.github_credential_scopes
  defp parsed_scopes(_), do: []

  defp normalize(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&normalize/1)
  end

  defp normalize(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {k, normalize(v)} end)
  end

  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.MomCliGitHubScopeVerificationScript.run()
