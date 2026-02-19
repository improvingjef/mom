defmodule Mom.Acceptance.MomCliActorAllowlistScript do
  def run do
    allowed_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-token",
        "token",
        "--actor-id",
        "mom-bot",
        "--allowed-actor-ids",
        "mom-bot,mom-staging"
      ])

    blocked_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-token",
        "token",
        "--actor-id",
        "personal-user",
        "--allowed-actor-ids",
        "mom-bot,mom-staging"
      ])

    missing_allowlist_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-token",
        "token",
        "--actor-id",
        "mom-bot"
      ])

    result = %{
      allowed_actor_id: allowed_actor_id(allowed_result),
      allowed_actor_ids: allowed_actor_ids(allowed_result),
      blocked_result: blocked_result,
      missing_allowlist_result: missing_allowlist_result
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  end

  defp allowed_actor_id({:ok, config}), do: config.actor_id
  defp allowed_actor_id(_), do: nil

  defp allowed_actor_ids({:ok, config}), do: config.allowed_actor_ids
  defp allowed_actor_ids(_), do: []

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

Mom.Acceptance.MomCliActorAllowlistScript.run()
