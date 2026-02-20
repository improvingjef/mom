defmodule Mom.Acceptance.MomCliToolchainPolicyAlignmentScript do
  import ExUnit.CaptureIO

  def run do
    original_node = System.get_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE")
    original_otp = System.get_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE")
    original_elixir = System.get_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE")

    result =
      try do
        System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", "v24.6.0")
        System.put_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", "28.0.2")
        System.put_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", "1.19.4")

        doctor_output =
          capture_io(fn -> Mix.Tasks.Mom.Doctor.run(["--format", "json", "--cwd", "."]) end)

        doctor_report = doctor_output |> String.trim() |> Jason.decode!()
        mix_exs = File.read!("mix.exs")
        tool_versions = File.read!(".tool-versions")
        mise_toml = File.read!("mise.toml")
        exunit_workflow = File.read!(".github/workflows/ci-exunit.yml")
        playwright_workflow = File.read!(".github/workflows/ci-playwright.yml")

        %{
          doctor_status: doctor_report["status"],
          required_elixir_version: doctor_report["required"]["elixir_version"],
          mix_exs_aligned: String.contains?(mix_exs, ~s(elixir: "~> 1.19.4")),
          tool_versions_aligned:
            String.contains?(tool_versions, "elixir 1.19.4-otp-28") and
              String.contains?(tool_versions, "erlang 28.0.2"),
          mise_aligned:
            String.contains?(mise_toml, ~s(elixir = "1.19.4-otp-28")) and
              String.contains?(mise_toml, ~s(erlang = "28.0.2")),
          ci_exunit_aligned:
            String.contains?(exunit_workflow, ~s(elixir-version: "1.19.4")) and
              String.contains?(exunit_workflow, ~s(otp-version: "28.0.2")),
          ci_playwright_aligned:
            String.contains?(playwright_workflow, ~s(elixir-version: "1.19.4")) and
              String.contains?(playwright_workflow, ~s(otp-version: "28.0.2"))
        }
      after
        restore_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", original_node)
        restore_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", original_otp)
        restore_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", original_elixir)
      end

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

Mom.Acceptance.MomCliToolchainPolicyAlignmentScript.run()
