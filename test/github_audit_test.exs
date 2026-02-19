defmodule Mom.GitHubAuditTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mom.{Config, GitHub}

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

  setup do
    previous = Application.get_env(:mom, :github_http_client)
    Application.put_env(:mom, :github_http_client, FakeGitHubHttpClient)

    on_exit(fn ->
      if previous do
        Application.put_env(:mom, :github_http_client, previous)
      else
        Application.delete_env(:mom, :github_http_client)
      end
    end)

    :ok
  end

  test "create_issue emits structured audit success event with actor and issue metadata" do
    Process.put(:github_http_responses, [
      {:ok,
       {{~c"HTTP/1.1", 201, ~c"Created"}, [], ~s({"html_url":"https://example/pr/1","number":77})}}
    ])

    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        github_repo: "acme/mom",
        github_token: "token",
        actor_id: "machine-user"
      )

    telemetry_handler = "github-audit-issue-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_handler,
      [[:mom, :audit, :github_issue_created]],
      fn event, _measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    log =
      capture_log(fn ->
        assert {:ok, %{number: 77}} = GitHub.create_issue(config, "title", "body")
      end)

    assert_receive {:telemetry_event, [:mom, :audit, :github_issue_created], metadata}
    assert metadata.repo == "acme/mom"
    assert metadata.actor_id == "machine-user"
    assert metadata.issue_number == 77
    assert log =~ "\"event\":\"github_issue_created\""
    assert log =~ "\"actor_id\":\"machine-user\""
  end

  test "merge_pr emits merge attempt and failure audit events" do
    Process.put(:github_http_responses, [
      {:ok, {{~c"HTTP/1.1", 422, ~c"Unprocessable Entity"}, [], "merge failed"}}
    ])

    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        github_repo: "acme/mom",
        github_token: "token",
        actor_id: "machine-user"
      )

    telemetry_handler = "github-audit-merge-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_handler,
      [[:mom, :audit, :github_merge_attempt], [:mom, :audit, :github_merge_failed]],
      fn event, _measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    log =
      capture_log(fn ->
        assert {:error, {:http_error, 422, "merge failed"}} =
                 GitHub.merge_pr(config, %{number: 33})
      end)

    assert_receive {:telemetry_event, [:mom, :audit, :github_merge_attempt], attempt_metadata}
    assert attempt_metadata.repo == "acme/mom"
    assert attempt_metadata.actor_id == "machine-user"
    assert attempt_metadata.pr_number == 33

    assert_receive {:telemetry_event, [:mom, :audit, :github_merge_failed], failure_metadata}
    assert failure_metadata.repo == "acme/mom"
    assert failure_metadata.actor_id == "machine-user"
    assert failure_metadata.pr_number == 33

    assert log =~ "\"event\":\"github_merge_attempt\""
    assert log =~ "\"event\":\"github_merge_failed\""
  end
end
