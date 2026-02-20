defmodule Mom.Acceptance.IncidentToPrSuccessScript do
  alias Mom.{Config, Git, GitHub, IncidentToPr}

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
      {:ok,
       {{~c"HTTP/1.1", 201, ~c"Created"}, [],
        ~s({"html_url":"https://example/issues/7","number":7})}},
      {:ok,
       {{~c"HTTP/1.1", 201, ~c"Created"}, [],
        ~s({"html_url":"https://example/pull/12","number":12})}}
    ])

    previous_client = Application.get_env(:mom, :github_http_client)
    Application.put_env(:mom, :github_http_client, FakeGitHubHttpClient)

    try do
      {:ok, config} =
        Config.from_opts(
          repo: "/tmp/repo",
          github_repo: "acme/mom",
          github_token: "token",
          github_credential_scopes: ["contents", "pull_requests", "issues"],
          open_pr: true,
          readiness_gate_approved: true,
          actor_id: "machine-bot",
          allowed_actor_ids: ["machine-bot"]
        )

      events = capture_events(fn -> run_incident_to_pr_flow(config) end)
      signal = IncidentToPr.evaluate(events.list)

      result = %{
        incident_to_pr_success: match?({:ok, _}, signal),
        saw_pr_event: event?(events.list, :github_pr_created),
        saw_issue_event: event?(events.list, :github_issue_created),
        saw_patch_event: event?(events.list, :git_patch_applied),
        saw_tests_event: event?(events.list, :git_tests_run),
        saw_push_event: event?(events.list, :git_branch_pushed),
        signal: normalize(elem(signal, 1))
      }

      IO.puts("RESULT_JSON:" <> Jason.encode!(result))
    after
      if previous_client do
        Application.put_env(:mom, :github_http_client, previous_client)
      else
        Application.delete_env(:mom, :github_http_client)
      end
    end
  end

  defp run_incident_to_pr_flow(config) do
    repo = create_repo()
    remote = create_bare_remote()
    git(repo, ["remote", "add", "origin", remote])

    workdir = new_workdir_path()
    :ok = Git.add_worktree(repo, workdir, actor_id: config.actor_id, repo: config.github_repo)

    {:ok, _issue} = GitHub.create_issue(config, "mom: production error detected", "incident body")

    :ok = Git.apply_patch(workdir, patch(), actor_id: config.actor_id, repo: config.github_repo)
    :ok = Git.run_tests(workdir, config)

    {:ok, branch} =
      Git.commit_changes(workdir, "mom: incident fix", "mom/incident",
        actor_id: config.actor_id,
        repo: config.github_repo
      )

    :ok = Git.push_branch(workdir, branch, actor_id: config.actor_id, repo: config.github_repo)
    {:ok, _pr} = GitHub.create_pr(config, branch)
    :ok
  end

  defp patch do
    """
    diff --git a/lib/sample.ex b/lib/sample.ex
    index 97fef5f..6fa8f57 100644
    --- a/lib/sample.ex
    +++ b/lib/sample.ex
    @@ -1,3 +1,3 @@
     defmodule Sample do
    -  def value, do: 1
    +  def value, do: 2
     end
    diff --git a/test/sample_test.exs b/test/sample_test.exs
    index e20eb85..ef43733 100644
    --- a/test/sample_test.exs
    +++ b/test/sample_test.exs
    @@ -2,6 +2,6 @@ defmodule SampleTest do
       use ExUnit.Case

       test "value" do
    -    assert Sample.value() == 1
    +    assert Sample.value() == 2
       end
     end
    """
  end

  defp capture_events(fun) do
    test_pid = self()
    handler_id = "mom-acceptance-incident-to-pr-#{System.unique_integer([:positive])}"

    telemetry_events =
      [
        :github_issue_created,
        :git_patch_applied,
        :git_tests_run,
        :git_branch_pushed,
        :github_pr_created
      ]
      |> Enum.map(&[:mom, :audit, &1])

    :ok =
      :telemetry.attach_many(
        handler_id,
        telemetry_events,
        fn event, _measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, metadata})
        end,
        test_pid
      )

    try do
      _ = fun.()
      %{list: drain_events([])}
    after
      :telemetry.detach(handler_id)
    end
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

  defp create_repo do
    base =
      Path.join(System.tmp_dir!(), "mom-incident-pr-repo-#{System.unique_integer([:positive])}")

    File.rm_rf!(base)
    File.mkdir_p!(Path.join(base, "lib"))
    File.mkdir_p!(Path.join(base, "test"))

    File.write!(Path.join(base, "mix.exs"), mix_project_source())

    File.write!(
      Path.join(base, "lib/sample.ex"),
      "defmodule Sample do\n  def value, do: 1\nend\n"
    )

    File.write!(Path.join(base, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(base, "test/sample_test.exs"),
      "defmodule SampleTest do\n  use ExUnit.Case\n\n  test \"value\" do\n    assert Sample.value() == 1\n  end\nend\n"
    )

    git(base, ["init"])
    git(base, ["config", "user.email", "mom@example.com"])
    git(base, ["config", "user.name", "mom"])
    git(base, ["add", "."])
    git(base, ["commit", "-m", "init"])
    base
  end

  defp mix_project_source do
    """
    defmodule Sample.MixProject do
      use Mix.Project

      def project do
        [app: :sample, version: "0.1.0", elixir: "~> 1.19", deps: []]
      end
    end
    """
  end

  defp create_bare_remote do
    remote =
      Path.join(
        System.tmp_dir!(),
        "mom-incident-pr-remote-#{System.unique_integer([:positive])}.git"
      )

    File.rm_rf!(remote)
    git(System.tmp_dir!(), ["init", "--bare", remote])
    remote
  end

  defp new_workdir_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "mom-incident-pr-worktree-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(path)
    path
  end

  defp git(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir)
    :ok
  end

  defp normalize(term) when is_map(term) do
    Map.new(term, fn {key, value} -> {to_string(key), normalize(value)} end)
  end

  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term), do: term
end

Mom.Acceptance.IncidentToPrSuccessScript.run()
