defmodule Mom.Acceptance.MomCliAllowlistScript do
  def run do
    {:ok, allowed_config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "acme/mom",
        "--allowed-github-repos",
        "acme/mom,acme/other"
      ])

    blocked_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "evil/repo",
        "--allowed-github-repos",
        "acme/mom,acme/other"
      ])

    result = %{
      allowed_repo: allowed_config.github_repo,
      allowed_list: allowed_config.allowed_github_repos,
      blocked_result: blocked_result
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  end

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

Mom.Acceptance.MomCliAllowlistScript.run()
