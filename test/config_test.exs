defmodule Mom.ConfigTest do
  use ExUnit.Case

  alias Mom.Config

  test "builds config from opts" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo", mode: :remote)
    assert config.repo == "/tmp/repo"
    assert config.mode == :remote
  end

  test "parses redact keys from comma-separated string" do
    {:ok, config} =
      Config.from_opts(repo: "/tmp/repo", redact_keys: "foo, Bar , ,baz")

    assert config.redact_keys == ["foo", "Bar", "baz"]
  end

  test "uses runtime env defaults" do
    Application.put_env(:mom, :llm_cmd, "cat")
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert config.llm_cmd == "cat"
  after
    Application.delete_env(:mom, :llm_cmd)
  end

  test "default redact keys include password" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert "password" in config.redact_keys
  end

  test "parses numeric env values" do
    Application.put_env(:mom, :issue_rate_limit_per_hour, "12")
    {:ok, config} = Config.from_opts(repo: "/tmp/repo")
    assert config.issue_rate_limit_per_hour == 12
  after
    Application.delete_env(:mom, :issue_rate_limit_per_hour)
  end
end
