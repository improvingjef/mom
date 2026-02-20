defmodule Mom.ToolchainPolicyParityTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("..", __DIR__)

  test "mix.exs, manifests, and CI workflows stay aligned to supported toolchain baseline" do
    mix_exs = File.read!(Path.join(@repo_root, "mix.exs"))
    tool_versions = File.read!(Path.join(@repo_root, ".tool-versions"))
    mise_toml = File.read!(Path.join(@repo_root, "mise.toml"))
    exunit_workflow = File.read!(Path.join(@repo_root, ".github/workflows/ci-exunit.yml"))
    playwright_workflow = File.read!(Path.join(@repo_root, ".github/workflows/ci-playwright.yml"))

    assert String.contains?(mix_exs, ~s(elixir: "~> 1.19.4"))
    assert String.contains?(tool_versions, "node 24.6.0")
    assert String.contains?(tool_versions, "erlang 28.0.2")
    assert String.contains?(tool_versions, "elixir 1.19.4-otp-28")
    assert String.contains?(mise_toml, ~s(node = "24.6.0"))
    assert String.contains?(mise_toml, ~s(erlang = "28.0.2"))
    assert String.contains?(mise_toml, ~s(elixir = "1.19.4-otp-28"))

    assert String.contains?(exunit_workflow, ~s(elixir-version: "1.19.4"))
    assert String.contains?(exunit_workflow, ~s(otp-version: "28.0.2"))
    assert String.contains?(playwright_workflow, ~s(elixir-version: "1.19.4"))
    assert String.contains?(playwright_workflow, ~s(otp-version: "28.0.2"))
  end
end
