defmodule Mix.Tasks.MomBootstrapTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "run writes .tool-versions and mise.toml" do
    base = Path.join(System.tmp_dir!(), "mom-bootstrap-#{System.unique_integer([:positive])}")
    File.rm_rf!(base)
    File.mkdir_p!(base)

    on_exit(fn -> File.rm_rf(base) end)

    output =
      capture_io(fn ->
        Mix.Tasks.Mom.Bootstrap.run([
          "--cwd",
          base,
          "--node-version",
          "24.6.0",
          "--otp-version",
          "28.0.2",
          "--elixir-version",
          "1.19.4-otp-28"
        ])
      end)

    assert String.contains?(output, "wrote")

    tool_versions = File.read!(Path.join(base, ".tool-versions"))
    assert String.contains?(tool_versions, "node 24.6.0")
    assert String.contains?(tool_versions, "erlang 28.0.2")
    assert String.contains?(tool_versions, "elixir 1.19.4-otp-28")

    mise_toml = File.read!(Path.join(base, "mise.toml"))
    assert String.contains?(mise_toml, "[tools]")
    assert String.contains?(mise_toml, ~s(node = "24.6.0"))
    assert String.contains?(mise_toml, ~s(erlang = "28.0.2"))
    assert String.contains?(mise_toml, ~s(elixir = "1.19.4-otp-28"))
  end
end
