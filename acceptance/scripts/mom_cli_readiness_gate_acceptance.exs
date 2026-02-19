defmodule Mom.Acceptance.MomCliReadinessGateScript do
  def run do
    System.put_env("MOM_GITHUB_TOKEN", "token")

    blocked_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "acme/mom",
        "--actor-id",
        "mom-app[bot]",
        "--allowed-actor-ids",
        "mom-app[bot]"
      ])

    approved_result =
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

    result = %{
      blocked_result: blocked_result,
      approved_gate: readiness_gate_approved(approved_result),
      approved_repo: github_repo(approved_result)
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  after
    System.delete_env("MOM_GITHUB_TOKEN")
  end

  defp readiness_gate_approved({:ok, config}), do: config.readiness_gate_approved
  defp readiness_gate_approved(_), do: false

  defp github_repo({:ok, config}), do: config.github_repo
  defp github_repo(_), do: nil

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

Mom.Acceptance.MomCliReadinessGateScript.run()
