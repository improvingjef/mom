defmodule Mom.Acceptance.GitHubAuditScript do
  alias Mom.{Config, Git, GitHub}

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
    Process.put(:github_http_responses, [
      {:ok, {{~c"HTTP/1.1", 201, ~c"Created"}, [], ~s({"html_url":"https://example/issues/7","number":7})}},
      {:ok, {{~c"HTTP/1.1", 201, ~c"Created"}, [], ~s({"html_url":"https://example/pull/9","number":9})}},
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s({"merged":true})}}
    ])

    Application.put_env(:mom, :github_http_client, FakeGitHubHttpClient)

    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        github_repo: "acme/mom",
        github_token: "token",
        actor_id: "machine-user",
        allowed_actor_ids: ["machine-user"]
      )

    events = capture_events(fn ->
      repo = create_repo()
      File.write!(Path.join(repo, "AUDIT.md"), "audit\n")

      {:ok, branch} =
        Git.commit_changes(
          repo,
          "mom: acceptance audit",
          "mom/audit",
          actor_id: config.actor_id,
          repo: config.github_repo
        )

      {:ok, issue} = GitHub.create_issue(config, "title", "body")
      {:ok, pr} = GitHub.create_pr(config, branch)
      :ok = GitHub.merge_pr(config, pr)

      %{branch: branch, issue_number: issue.number, pr_number: pr.number}
    end)

    result = %{
      saw_branch_event: event?(events.list, :git_branch_created),
      saw_issue_event: event?(events.list, :github_issue_created),
      saw_pr_event: event?(events.list, :github_pr_created),
      saw_merge_attempt_event: event?(events.list, :github_merge_attempt),
      branch_event_fields: required_fields?(events.list, :git_branch_created, [:repo, :actor_id, :branch]),
      issue_event_fields: required_fields?(events.list, :github_issue_created, [:repo, :actor_id, :issue_number]),
      pr_event_fields: required_fields?(events.list, :github_pr_created, [:repo, :actor_id, :pr_number, :branch]),
      merge_attempt_fields: required_fields?(events.list, :github_merge_attempt, [:repo, :actor_id, :pr_number]),
      branch: events.payload.branch,
      issue_number: events.payload.issue_number,
      pr_number: events.payload.pr_number
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  end

  defp capture_events(fun) do
    test_pid = self()
    handler_id = "mom-acceptance-audit-#{System.unique_integer([:positive])}"

    event_names = [
      :git_branch_created,
      :github_issue_created,
      :github_pr_created,
      :github_merge_attempt
    ]

    telemetry_events = Enum.map(event_names, &[:mom, :audit, &1])

    :ok =
      :telemetry.attach_many(
        handler_id,
        telemetry_events,
        fn event, _measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, metadata})
        end,
        test_pid
      )

    payload = fun.()

    list = drain_events([])
    :telemetry.detach(handler_id)
    %{list: list, payload: payload}
  end

  defp drain_events(acc) do
    receive do
      {:telemetry_event, event, metadata} ->
        drain_events([{event, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp event?(events, name) do
    Enum.any?(events, fn
      {[:mom, :audit, ^name], _metadata} -> true
      _ -> false
    end)
  end

  defp required_fields?(events, name, keys) do
    case Enum.find(events, fn
           {[:mom, :audit, ^name], _metadata} -> true
           _ -> false
         end) do
      {_, metadata} -> Enum.all?(keys, &Map.has_key?(metadata, &1))
      nil -> false
    end
  end

  defp create_repo do
    base = Path.join(System.tmp_dir!(), "mom-acceptance-repo-#{System.unique_integer([:positive])}")
    File.rm_rf!(base)
    File.mkdir_p!(base)

    git(base, ["init"])
    git(base, ["config", "user.email", "mom@example.com"])
    git(base, ["config", "user.name", "mom"])

    File.write!(Path.join(base, "README.md"), "mom acceptance\n")
    git(base, ["add", "."])
    git(base, ["commit", "-m", "init"])

    base
  end

  defp git(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir)
    :ok
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

Mom.Acceptance.GitHubAuditScript.run()
