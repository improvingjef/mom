defmodule Mom.Acceptance.MomCliToolchainDoctorBootstrapScript do
  import ExUnit.CaptureIO

  def run do
    base =
      Path.join(System.tmp_dir!(), "mom-doctor-bootstrap-#{System.unique_integer([:positive])}")

    File.rm_rf!(base)
    File.mkdir_p!(base)

    original_node = System.get_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE")
    original_otp = System.get_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE")
    original_elixir = System.get_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE")

    result =
      try do
        System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", "v16.20.2")
        System.put_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", "28.0.1")
        System.put_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", "1.19.0-rc.0")

        failing_output =
          capture_io(fn -> Mix.Tasks.Mom.Doctor.run(["--format", "json", "--cwd", base]) end)

        failing_report = failing_output |> String.trim() |> Jason.decode!()

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

        System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", "v24.6.0")
        System.put_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", "28.0.2")
        System.put_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", "1.19.4")

        healthy_output =
          capture_io(fn -> Mix.Tasks.Mom.Doctor.run(["--format", "json", "--cwd", base]) end)

        healthy_report = healthy_output |> String.trim() |> Jason.decode!()

        %{
          failing_status: failing_report["status"],
          failing_has_node_error:
            Enum.any?(
              failing_report["checks"],
              &(&1["id"] == "node_runtime" and &1["status"] == "error")
            ),
          bootstrap_tool_versions_exists: File.exists?(Path.join(base, ".tool-versions")),
          bootstrap_mise_exists: File.exists?(Path.join(base, "mise.toml")),
          healthy_status: healthy_report["status"],
          healthy_manifest_checks_ok:
            Enum.all?(healthy_report["checks"], fn check ->
              if check["id"] in ["tool_versions_manifest", "mise_manifest"] do
                check["status"] == "ok"
              else
                true
              end
            end)
        }
      after
        restore_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", original_node)
        restore_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", original_otp)
        restore_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", original_elixir)
        File.rm_rf(base)
      end

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

Mom.Acceptance.MomCliToolchainDoctorBootstrapScript.run()
