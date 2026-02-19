defmodule Mom.Acceptance.MomCliPrOnlyScript do
  defmodule FakeGitHubHttpClient do
    def request(_method, _request, _http_options, _options) do
      case Process.get(:github_http_responses, []) do
        [response | rest] ->
          Process.put(:github_http_responses, rest)
          response

        [] ->
          {:error, :no_response}
      end
    end
  end

  def run do
    System.put_env("MOM_GITHUB_TOKEN", "token")
    previous = Application.get_env(:mom, :github_http_client)
    Application.put_env(:mom, :github_http_client, FakeGitHubHttpClient)
    Process.put(:github_http_responses, [ok_merge_response()])

    handler_id = "mom-cli-pr-only-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:mom, :audit, :github_merge_blocked], [:mom, :audit, :github_merged]],
        fn event, _measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, metadata})
        end,
        self()
      )

    try do
      {:ok, protected_config} =
        Mix.Tasks.Mom.parse_args([
          "/tmp/repo",
          "--github-repo",
          "acme/mom",
          "--github-base-branch",
          "main",
          "--protected-branches",
          "main,release",
          "--actor-id",
          "machine-bot",
          "--allowed-actor-ids",
          "machine-bot"
        ])

      {:ok, unprotected_config} =
        Mix.Tasks.Mom.parse_args([
          "/tmp/repo",
          "--github-repo",
          "acme/mom",
          "--github-base-branch",
          "dev",
          "--protected-branches",
          "main,release",
          "--actor-id",
          "machine-bot",
          "--allowed-actor-ids",
          "machine-bot"
        ])

      protected_merge_result = Mom.GitHub.merge_pr(protected_config, %{number: 10})
      unprotected_merge_result = Mom.GitHub.merge_pr(unprotected_config, %{number: 11})

      blocked_event = await_telemetry([:mom, :audit, :github_merge_blocked])
      merged_event = await_telemetry([:mom, :audit, :github_merged])

      result = %{
        protected_base_branch: protected_config.github_base_branch,
        protected_branches: protected_config.protected_branches,
        protected_merge_result: protected_merge_result,
        blocked_event_base_branch: blocked_event.base_branch,
        unprotected_base_branch: unprotected_config.github_base_branch,
        unprotected_merge_result: unprotected_merge_result,
        merged_pr_number: merged_event.pr_number
      }

      IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
    after
      :telemetry.detach(handler_id)

      if previous do
        Application.put_env(:mom, :github_http_client, previous)
      else
        Application.delete_env(:mom, :github_http_client)
      end

      System.delete_env("MOM_GITHUB_TOKEN")
    end
  end

  defp ok_merge_response do
    {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s({"merged":true})}}
  end

  defp await_telemetry(event_name) do
    receive do
      {:telemetry_event, ^event_name, metadata} -> metadata
    after
      1_000 -> raise "missing telemetry event: #{inspect(event_name)}"
    end
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

Mom.Acceptance.MomCliPrOnlyScript.run()
