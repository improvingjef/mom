defmodule Mom.Acceptance.MomCliMachineIdentityScript do
  def run do
    System.put_env("MOM_GITHUB_TOKEN", "token")
    System.put_env("MOM_GITHUB_CREDENTIAL_SCOPES", "contents,pull_requests,issues")

    machine_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--actor-id",
        "mom-app[bot]",
        "--allowed-actor-ids",
        "mom-app[bot]"
      ])

    human_actor_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--actor-id",
        "jef",
        "--allowed-actor-ids",
        "jef"
      ])

    result = %{
      machine_actor: machine_actor(machine_result),
      human_actor_result: human_actor_result
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  after
    System.delete_env("MOM_GITHUB_TOKEN")
    System.delete_env("MOM_GITHUB_CREDENTIAL_SCOPES")
  end

  defp machine_actor({:ok, config}), do: config.actor_id
  defp machine_actor(_), do: nil

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

Mom.Acceptance.MomCliMachineIdentityScript.run()
