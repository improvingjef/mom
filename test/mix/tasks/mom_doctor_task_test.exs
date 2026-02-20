defmodule Mix.Tasks.MomDoctorTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    original_node = System.get_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE")
    original_otp = System.get_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE")
    original_elixir = System.get_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE")

    on_exit(fn ->
      restore_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", original_node)
      restore_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", original_otp)
      restore_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", original_elixir)
    end)

    :ok
  end

  test "parse_args defaults to text format" do
    assert {:ok, opts} = Mix.Tasks.Mom.Doctor.parse_args([])
    assert opts.format == :text
    assert opts.cwd == "."
    refute opts.fail_on_error
  end

  test "parse_args accepts json and fail-on-error" do
    assert {:ok, opts} =
             Mix.Tasks.Mom.Doctor.parse_args([
               "--format",
               "json",
               "--cwd",
               "/tmp",
               "--fail-on-error"
             ])

    assert opts.format == :json
    assert opts.cwd == "/tmp"
    assert opts.fail_on_error
  end

  test "run reports actionable failures in json format" do
    System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", "v16.20.2")
    System.put_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", "28.0.1")
    System.put_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", "1.19.0-rc.0")

    output =
      capture_io(fn ->
        Mix.Tasks.Mom.Doctor.run(["--format", "json", "--cwd", "."])
      end)

    report = output |> String.trim() |> Jason.decode!()

    assert report["status"] == "error"
    assert report["required"]["elixir_version"] == "1.19.4"
    assert Enum.any?(report["checks"], &(&1["id"] == "node_runtime" and &1["status"] == "error"))

    assert Enum.any?(report["checks"], fn check ->
             check["id"] == "node_runtime" and
               String.contains?(check["remediation"], "Install Node")
           end)
  end

  test "run fails when fail-on-error is enabled and checks fail" do
    System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", "v16.20.2")

    assert_raise Mix.Error, ~r/mom.doctor found toolchain preflight issues/, fn ->
      Mix.Tasks.Mom.Doctor.run(["--fail-on-error"])
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)

  defp restore_env(key, value) do
    System.put_env(key, value)
  end
end
