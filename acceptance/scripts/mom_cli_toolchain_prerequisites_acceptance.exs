defmodule Mom.Acceptance.MomCliToolchainPrerequisitesScript do
  def run do
    original_node_override = System.get_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE")
    original_otp_override = System.get_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE")
    original_elixir_override = System.get_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE")

    result =
      try do
        System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", "v16.20.2")
        node_blocked = Mix.Tasks.Mom.parse_args(["/tmp/repo"])

        System.put_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", "v24.6.0")
        System.put_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", "28.0.1")
        otp_blocked = Mix.Tasks.Mom.parse_args(["/tmp/repo"])

        System.put_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", "28.0.2")
        System.put_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", "1.19.0-rc.0")
        elixir_rc_blocked = Mix.Tasks.Mom.parse_args(["/tmp/repo"])

        System.put_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", "1.19.3")
        elixir_patch_blocked = Mix.Tasks.Mom.parse_args(["/tmp/repo"])

        System.put_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", "1.18.4")
        elixir_series_blocked = Mix.Tasks.Mom.parse_args(["/tmp/repo"])

        System.put_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", "1.19.4")
        System.put_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", "28.0.2")
        {:ok, parsed} = Mix.Tasks.Mom.parse_args(["/tmp/repo"])

        %{
          node_blocked: normalize(node_blocked),
          otp_blocked: normalize(otp_blocked),
          elixir_rc_blocked: normalize(elixir_rc_blocked),
          elixir_patch_blocked: normalize(elixir_patch_blocked),
          elixir_series_blocked: normalize(elixir_series_blocked),
          valid_mode: Atom.to_string(parsed.mode)
        }
      after
        restore_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE", original_node_override)
        restore_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE", original_otp_override)
        restore_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE", original_elixir_override)
      end

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp normalize({:ok, value}), do: ["ok", normalize(value)]
  defp normalize({:error, value}), do: ["error", normalize(value)]
  defp normalize(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&normalize/1)
  defp normalize(term) when is_map(term), do: Map.new(term, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.MomCliToolchainPrerequisitesScript.run()
