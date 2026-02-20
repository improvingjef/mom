defmodule Mom.Acceptance.MomCliToolchainBumpWorkflowScript do
  import ExUnit.CaptureIO

  def run do
    base =
      Path.join(System.tmp_dir!(), "mom-bump-toolchain-acceptance-#{System.unique_integer([:positive])}")

    File.rm_rf!(base)
    File.mkdir_p!(base)

    result =
      try do
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

        mix_exs = File.read!(Path.join(base, "mix.exs"))
        tool_versions = File.read!(Path.join(base, ".tool-versions"))
        mise_toml = File.read!(Path.join(base, "mise.toml"))
        exunit_workflow = File.read!(Path.join(base, ".github/workflows/ci-exunit.yml"))
        playwright_workflow = File.read!(Path.join(base, ".github/workflows/ci-playwright.yml"))

        %{
          command_verified_parity: String.contains?(output, "verified toolchain parity"),
          mix_exs_aligned: String.contains?(mix_exs, ~s(elixir: "~> 1.19.5")),
          tool_versions_aligned:
            String.contains?(tool_versions, "node 26.1.0") and
              String.contains?(tool_versions, "erlang 28.1.1") and
              String.contains?(tool_versions, "elixir 1.19.5-otp-28"),
          mise_aligned:
            String.contains?(mise_toml, ~s(node = "26.1.0")) and
              String.contains?(mise_toml, ~s(erlang = "28.1.1")) and
              String.contains?(mise_toml, ~s(elixir = "1.19.5-otp-28")),
          ci_exunit_aligned:
            String.contains?(exunit_workflow, ~s(elixir-version: "1.19.5")) and
              String.contains?(exunit_workflow, ~s(otp-version: "28.1.1")),
          ci_playwright_aligned:
            String.contains?(playwright_workflow, ~s(elixir-version: "1.19.5")) and
              String.contains?(playwright_workflow, ~s(otp-version: "28.1.1"))
        }
      after
        File.rm_rf(base)
      end

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp seed_repo_fixture(base) do
    source = File.cwd!()

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

Mom.Acceptance.MomCliToolchainBumpWorkflowScript.run()
