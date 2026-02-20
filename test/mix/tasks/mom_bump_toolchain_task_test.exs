defmodule Mix.Tasks.MomBumpToolchainTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "run updates mix.exs, toolchain manifests, and ci workflow pins with parity verification" do
    base = Path.join(System.tmp_dir!(), "mom-bump-toolchain-#{System.unique_integer([:positive])}")
    File.rm_rf!(base)
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    seed_repo_fixture(base)

    output =
      capture_io(fn ->
        Mix.Tasks.Mom.BumpToolchain.run([
          "--cwd",
          base,
          "--node-version",
          "26.1.0",
          "--otp-version",
          "28.1.1",
          "--elixir-version",
          "1.19.5"
        ])
      end)

    assert output =~ "verified"
    assert File.read!(Path.join(base, "mix.exs")) =~ ~s(elixir: "~> 1.19.5")
    assert File.read!(Path.join(base, ".tool-versions")) =~ "node 26.1.0"
    assert File.read!(Path.join(base, ".tool-versions")) =~ "erlang 28.1.1"
    assert File.read!(Path.join(base, ".tool-versions")) =~ "elixir 1.19.5-otp-28"
    assert File.read!(Path.join(base, "mise.toml")) =~ ~s(node = "26.1.0")
    assert File.read!(Path.join(base, "mise.toml")) =~ ~s(erlang = "28.1.1")
    assert File.read!(Path.join(base, "mise.toml")) =~ ~s(elixir = "1.19.5-otp-28")
    assert File.read!(Path.join(base, ".github/workflows/ci-exunit.yml")) =~ ~s(elixir-version: "1.19.5")
    assert File.read!(Path.join(base, ".github/workflows/ci-exunit.yml")) =~ ~s(otp-version: "28.1.1")

    assert File.read!(Path.join(base, ".github/workflows/ci-playwright.yml")) =~
             ~s(elixir-version: "1.19.5")

    assert File.read!(Path.join(base, ".github/workflows/ci-playwright.yml")) =~
             ~s(otp-version: "28.1.1")
  end

  defp seed_repo_fixture(base) do
    source = Path.expand("..", Path.expand("..", Path.expand("..", __DIR__)))

    for relative <- [
          "mix.exs",
          ".tool-versions",
          "mise.toml",
          ".github/workflows/ci-exunit.yml",
          ".github/workflows/ci-playwright.yml"
        ] do
      destination = Path.join(base, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, File.read!(Path.join(source, relative)))
    end
  end
end
