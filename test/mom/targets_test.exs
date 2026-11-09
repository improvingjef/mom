defmodule Mom.TargetsTest do
  use ExUnit.Case, async: true

  alias Mom.Targets
  alias Mom.Targets.{Target, Watcher}

  @json ~s([{"name": "school", "node": "school@172.30.2.137", "triage": "off"},
            {"name": "latte", "node": "latte@172.30.2.120", "triage": "report", "agent": "claude_code"},
            {"name": "revive-hub", "node": "hub@10.0.0.5", "triage": "fix", "agent": "codex"}])

  test "parses the design's example list with cookies from the env map" do
    cookies =
      Targets.cookies_from_env(%{
        "MOM_TARGET_COOKIE_LATTE" => "c1",
        "MOM_TARGET_COOKIE_REVIVE_HUB" => "c2",
        "PATH" => "/bin"
      })

    assert {:ok, [school, latte, hub]} = Targets.parse(@json, cookies)

    assert %Target{
             name: "school",
             node: :"school@172.30.2.137",
             triage: :off,
             agent: :claude_code,
             cookie: nil
           } = school

    assert %Target{name: "latte", triage: :report, agent: :claude_code, cookie: :c1} = latte

    assert %Target{
             name: "revive-hub",
             node: :"hub@10.0.0.5",
             triage: :fix,
             agent: :codex,
             cookie: :c2
           } = hub
  end

  test "cookie env var name is upper case with - as _" do
    assert Targets.cookie_env_var("revive-hub") == "MOM_TARGET_COOKIE_REVIVE_HUB"
  end

  test "empty or missing list gives no targets" do
    assert {:ok, []} = Targets.parse(nil)
    assert {:ok, []} = Targets.parse("")
    assert {:ok, []} = Targets.parse("[]")
  end

  test "rejects bad input with the position and the reason" do
    assert {:error, "targets: invalid JSON" <> _} = Targets.parse("[{")
    assert {:error, "targets: expected a JSON list"} = Targets.parse(~s({"name": "x"}))
    assert {:error, "targets[0]: name is required" <> _} = Targets.parse(~s([{"node": "a@b"}]))

    assert {:error, "targets[0]: invalid name" <> _} =
             Targets.parse(~s([{"name": "a b", "node": "a@b"}]))

    assert {:error, "targets[0]: node must be name@host" <> _} =
             Targets.parse(~s([{"name": "a", "node": "ab"}]))

    assert {:error, "targets[0]: triage must be one of off|report|fix" <> _} =
             Targets.parse(~s([{"name": "a", "node": "a@b", "triage": "loud"}]))

    assert {:error, "targets[0]: agent must be one of claude_code|codex" <> _} =
             Targets.parse(~s([{"name": "a", "node": "a@b", "agent": "gpt"}]))

    assert {:error, "targets: duplicate name \"a\""} =
             Targets.parse(~s([{"name": "a", "node": "a@b"}, {"name": "a", "node": "c@d"}]))
  end

  test "watcher config options: node, agent, triage, repo from project info, own cookie kept" do
    target = %Target{name: "latte", node: :latte@h, cookie: :secret, triage: :off, agent: :codex}

    opts = Watcher.config_opts(target, nil, config_opts: [])
    assert opts[:node] == :latte@h
    assert opts[:cookie] == nil
    assert opts[:mode] == :remote
    assert opts[:llm_provider] == :codex
    assert opts[:triage_mode] == :report
    refute Keyword.has_key?(opts, :github_repo)
    assert String.ends_with?(opts[:repo], "checkouts/latte")

    opts =
      Watcher.config_opts(%{target | triage: :fix}, "improvingjef/latte",
        config_opts: [poll_interval_ms: 7]
      )

    assert opts[:triage_mode] == :fix
    assert opts[:github_repo] == "improvingjef/latte"
    assert opts[:poll_interval_ms] == 7

    assert {:ok, config} = Mom.Config.from_opts(opts)
    assert config.runtime.node == :latte@h
    assert config.llm.provider == :codex
    assert config.governance.github_repo == "improvingjef/latte"
    assert config.diagnostics.triage_mode == :fix
  end

  test "classifies runner messages for the status" do
    assert {:error, "error", "boom 42"} =
             Watcher.classify({:mom_log, %{level: :error, msg: {~c"boom ~p", [42]}, meta: %{}}})

    assert {:error, "error", "plain"} =
             Watcher.classify({:mom_log, %{level: :error, msg: {:string, "plain"}, meta: %{}}})

    assert {:error, "phoenix", "RuntimeError: bad"} =
             Watcher.classify(
               {:mom_telemetry,
                %{
                  event: [:phoenix, :router_dispatch, :exception],
                  metadata: %{kind: :error, reason: %RuntimeError{message: "bad"}}
                }}
             )

    assert {:error, "oban", "MyWorker: RuntimeError: x"} =
             Watcher.classify(
               {:mom_telemetry,
                %{
                  event: [:oban, :job, :exception],
                  metadata: %{worker: "MyWorker", error: %RuntimeError{message: "x"}}
                }}
             )

    assert {:event, "vm.memory"} = Watcher.classify({:mom_telemetry, %{event: [:vm, :memory]}})

    assert {:event, "system_monitor.long_gc"} =
             Watcher.classify({:mom_system_monitor, %{type: :long_gc}})

    assert :ignore = Watcher.classify(:other)
  end
end
