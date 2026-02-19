defmodule Mom.Acceptance.MomCliEgressPolicyScript do
  def run do
    {:ok, allowed_config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "api_openai",
        "--allowed-egress-hosts",
        "api.github.com,api.openai.com"
      ])

    blocked_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "api_openai",
        "--allowed-egress-hosts",
        "api.github.com,api.anthropic.com"
      ])

    result = %{
      allowed_egress_hosts: allowed_config.allowed_egress_hosts,
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

Mom.Acceptance.MomCliEgressPolicyScript.run()
