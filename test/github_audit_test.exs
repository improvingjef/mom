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
        github_credential_scopes: ["contents", "pull_requests", "issues"],
        open_pr: false,
        actor_id: "machine-bot",
        allowed_actor_ids: ["machine-bot"]
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
    assert metadata.actor_id == "machine-bot"
    assert metadata.issue_number == 77
    assert log =~ "\"event\":\"github_issue_created\""
    assert log =~ "\"actor_id\":\"machine-bot\""
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
        github_credential_scopes: ["contents", "pull_requests", "issues"],
        open_pr: false,
        actor_id: "machine-bot",
        allowed_actor_ids: ["machine-bot"],
        github_base_branch: "release",
        protected_branches: ["main"]
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
    assert attempt_metadata.actor_id == "machine-bot"
    assert attempt_metadata.pr_number == 33

    assert_receive {:telemetry_event, [:mom, :audit, :github_merge_failed], failure_metadata}
    assert failure_metadata.repo == "acme/mom"
    assert failure_metadata.actor_id == "machine-bot"
    assert failure_metadata.pr_number == 33

    assert log =~ "\"event\":\"github_merge_attempt\""
    assert log =~ "\"event\":\"github_merge_failed\""
  end

  test "merge_pr is blocked for protected base branches and emits audit event" do
    Process.put(:github_http_responses, [])

    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        github_repo: "acme/mom",
        github_token: "token",
        github_credential_scopes: ["contents", "pull_requests", "issues"],
        open_pr: false,
        actor_id: "machine-bot",
        allowed_actor_ids: ["machine-bot"],
        github_base_branch: "main",
        protected_branches: ["main", "release"]
      )

    telemetry_handler = "github-audit-merge-blocked-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_handler,
      [[:mom, :audit, :github_merge_blocked]],
      fn event, _measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    log =
      capture_log(fn ->
        assert :ok = GitHub.merge_pr(config, %{number: 33})
      end)

    assert_receive {:telemetry_event, [:mom, :audit, :github_merge_blocked], metadata}
    assert metadata.repo == "acme/mom"
    assert metadata.actor_id == "machine-bot"
    assert metadata.pr_number == 33
    assert metadata.base_branch == "main"
    assert log =~ "\"event\":\"github_merge_blocked\""
  end

  test "audit logs redact sensitive metadata fields" do
    log =
      capture_log(fn ->
        :ok =
          Mom.Audit.emit(:github_issue_failed, %{
            repo: "acme/mom",
            token: "ghp_123",
            nested: %{authorization: "Bearer abc", cookie: "_session=secret"}
          })
      end)

    assert log =~ "\"event\":\"github_issue_failed\""
    assert log =~ "\"token\":\"[REDACTED]\""
    assert log =~ "\"authorization\":\"[REDACTED]\""
    assert log =~ "\"cookie\":\"[REDACTED]\""
    refute log =~ "ghp_123"
    refute log =~ "Bearer abc"
    refute log =~ "_session=secret"
  end

  test "github calls are blocked when egress host is not allowlisted" do
    {:ok, base_config} =
      Config.from_opts(
        repo: "/tmp/repo",
        github_repo: "acme/mom",
        github_token: "token",
        github_credential_scopes: ["contents", "pull_requests", "issues"],
        open_pr: false,
        actor_id: "machine-bot",
        allowed_actor_ids: ["machine-bot"]
      )

    config = %{
      base_config
      | governance: %{base_config.governance | allowed_egress_hosts: ["api.openai.com"]}
    }

    assert {:error, {:egress_blocked, "api.github.com"}} =
             GitHub.create_issue(config, "title", "body")
  end
end
