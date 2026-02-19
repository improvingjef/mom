defmodule Mom.Acceptance.MomCliGitHubPermissionEvidenceScript do
  defmodule FakeGitHubPermissionHttpClient do
    def request(_method, _request, _http_options, _options) do
      case Process.get(:github_permission_http_responses, []) do
        [response | rest] ->
          Process.put(:github_permission_http_responses, rest)
          response

        [] ->
          {:error, :no_response}
      end
    end
  end

  def run do
    previous_http_client = Application.get_env(:mom, :github_http_client)

    try do
      Application.put_env(:mom, :github_http_client, FakeGitHubPermissionHttpClient)

      System.put_env("MOM_GITHUB_TOKEN", "token")
      System.put_env("MOM_STARTUP_ATTESTATION_SIGNING_KEY", "acceptance-signing-key")

      blocked_result =
        with_responses(
          [
            {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"x-oauth-scopes", ~c"read:user"}], ~c"{}"}},
            {:ok,
             {{~c"HTTP/1.1", 200, ~c"OK"}, [],
              ~s({"permissions":{"contents":"read","pull_requests":"read","issues":"read"}})}}
          ],
          fn ->
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
          end
        )

      passing_result =
        with_responses(
          [
            {:ok,
             {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"x-oauth-scopes", ~c"repo,workflow"}], ~c"{}"}},
            {:ok,
             {{~c"HTTP/1.1", 200, ~c"OK"}, [],
              ~s({"permissions":{"contents":"write","pull_requests":"write","issues":"write"}})}}
          ],
          fn ->
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
          end
        )

      result = %{
        blocked_result: blocked_result,
        passing_result: summarize_passing(passing_result)
      }

      IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
    after
      restore_http_client(previous_http_client)
      System.delete_env("MOM_GITHUB_TOKEN")
      System.delete_env("MOM_STARTUP_ATTESTATION_SIGNING_KEY")
    end
  end

  defp with_responses(responses, fun) do
    Process.put(:github_permission_http_responses, responses)
    fun.()
  end

  defp summarize_passing({:ok, config}) do
    %{
      actor_id: config.actor_id,
      github_repo: config.github_repo
    }
  end

  defp summarize_passing(other), do: other

  defp restore_http_client(nil), do: Application.delete_env(:mom, :github_http_client)
  defp restore_http_client(client), do: Application.put_env(:mom, :github_http_client, client)

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

Mom.Acceptance.MomCliGitHubPermissionEvidenceScript.run()
