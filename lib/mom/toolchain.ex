defmodule Mom.Toolchain do
  @moduledoc false

  @minimum_node_major 18
  @required_otp_version "28.0.2"
  @required_elixir_version "1.19.4"
  @default_bootstrap_node_version "24.6.0"
  @default_bootstrap_elixir_version "1.19.4-otp-28"

  @type check_status :: :ok | :error

  @spec validate(keyword(), keyword()) :: :ok | {:error, String.t()}
  def validate(opts \\ [], runtime \\ Application.get_all_env(:mom)) do
    with {:ok, node_version} <- detect_node_version(opts, runtime),
         :ok <- validate_node_version(node_version, required_node_major(runtime)),
         {:ok, otp_version} <- detect_otp_version(opts, runtime),
         :ok <- validate_otp_version(otp_version, required_otp_version(runtime)),
         {:ok, elixir_version} <- detect_elixir_version(opts, runtime),
         :ok <- validate_elixir_version(elixir_version, required_elixir_version(runtime)) do
      :ok
    end
  end

  @spec doctor(String.t(), keyword(), keyword()) :: map()
  def doctor(cwd \\ ".", opts \\ [], runtime \\ Application.get_all_env(:mom)) do
    required = required_toolchain(runtime)

    {node_version, node_check} =
      runtime_check(
        :node_runtime,
        fn -> detect_node_version(opts, runtime) end,
        fn version ->
          validate_node_version(version, required.node_major)
        end,
        fn ->
          "Install Node.js >= #{required.node_major}.x and ensure `node --version` succeeds."
        end
      )

    {otp_version, otp_check} =
      runtime_check(
        :otp_runtime,
        fn -> detect_otp_version(opts, runtime) end,
        fn version ->
          validate_otp_version(version, required.otp_version)
        end,
        fn ->
          "Install Erlang/OTP #{required.otp_version} (for asdf: `asdf install erlang #{required.otp_version}`)."
        end
      )

    {elixir_version, elixir_check} =
      runtime_check(
        :elixir_runtime,
        fn -> detect_elixir_version(opts, runtime) end,
        fn version ->
          validate_elixir_version(version, required.elixir_version)
        end,
        fn ->
          "Install stable Elixir #{required.elixir_version} (for asdf: `asdf install elixir #{required.bootstrap_elixir_version}`)."
        end
      )

    manifest_checks = [
      tool_versions_manifest_check(cwd, required),
      mise_manifest_check(cwd, required)
    ]

    checks = [node_check, otp_check, elixir_check | manifest_checks]

    %{
      status: overall_status(checks),
      required: %{
        node_major: required.node_major,
        otp_version: required.otp_version,
        elixir_version: required.elixir_version,
        bootstrap_node_version: required.bootstrap_node_version,
        bootstrap_elixir_version: required.bootstrap_elixir_version
      },
      detected: %{
        node_version: node_version,
        otp_version: otp_version,
        elixir_version: elixir_version
      },
      checks: checks
    }
  end

  @spec bootstrap(String.t(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def bootstrap(cwd, overrides \\ [], runtime \\ Application.get_all_env(:mom)) do
    defaults = required_toolchain(runtime)
    node_version = Keyword.get(overrides, :node_version, defaults.bootstrap_node_version)
    otp_version = Keyword.get(overrides, :otp_version, defaults.otp_version)
    elixir_version = Keyword.get(overrides, :elixir_version, defaults.bootstrap_elixir_version)

    tool_versions_path = Path.join(cwd, ".tool-versions")
    mise_path = Path.join(cwd, "mise.toml")

    with :ok <- File.mkdir_p(cwd),
         :ok <-
           File.write(
             tool_versions_path,
             tool_versions_content(node_version, otp_version, elixir_version)
           ),
         :ok <-
           File.write(mise_path, mise_toml_content(node_version, otp_version, elixir_version)) do
      {:ok,
       %{
         tool_versions_path: tool_versions_path,
         mise_path: mise_path,
         node_version: node_version,
         otp_version: otp_version,
         elixir_version: elixir_version
       }}
    end
  end

  @spec bootstrap_defaults(keyword()) :: map()
  def bootstrap_defaults(runtime \\ Application.get_all_env(:mom)) do
    required = required_toolchain(runtime)

    %{
      node_version: required.bootstrap_node_version,
      otp_version: required.otp_version,
      elixir_version: required.bootstrap_elixir_version
    }
  end

  defp required_toolchain(runtime) do
    %{
      node_major: required_node_major(runtime),
      otp_version: required_otp_version(runtime),
      elixir_version: required_elixir_version(runtime),
      bootstrap_node_version: bootstrap_node_version(runtime),
      bootstrap_elixir_version: bootstrap_elixir_version(runtime)
    }
  end

  defp runtime_check(id, detect_fun, validate_fun, remediation_fun) do
    case detect_fun.() do
      {:ok, version} ->
        case validate_fun.(version) do
          :ok ->
            {version, check(id, :ok, "ok", nil)}

          {:error, reason} ->
            {version, check(id, :error, reason, remediation_fun.())}
        end

      {:error, reason} ->
        {nil, check(id, :error, reason, remediation_fun.())}
    end
  end

  defp check(id, status, message, remediation) when status in [:ok, :error] do
    %{
      id: Atom.to_string(id),
      status: Atom.to_string(status),
      message: message,
      remediation: remediation
    }
  end

  defp overall_status(checks) do
    if Enum.any?(checks, &(&1.status == "error")), do: "error", else: "ok"
  end

  defp tool_versions_manifest_check(cwd, required) do
    path = Path.join(cwd, ".tool-versions")

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         map <- parse_tool_versions(body),
         :ok <- validate_manifest_versions(map, required) do
      check(:tool_versions_manifest, :ok, "#{path} is aligned", nil)
    else
      false ->
        check(
          :tool_versions_manifest,
          :error,
          "#{path} is missing",
          "Run `mix mom.bootstrap --cwd #{cwd}` to generate .tool-versions and mise.toml."
        )

      {:error, reason} ->
        check(
          :tool_versions_manifest,
          :error,
          ".tool-versions validation failed: #{reason}",
          "Run `mix mom.bootstrap --cwd #{cwd}` to repair toolchain manifests."
        )

      _other ->
        check(
          :tool_versions_manifest,
          :error,
          ".tool-versions validation failed",
          "Run `mix mom.bootstrap --cwd #{cwd}` to repair toolchain manifests."
        )
    end
  end

  defp mise_manifest_check(cwd, required) do
    path = Path.join(cwd, "mise.toml")

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         map <- parse_mise_toml(body),
         :ok <- validate_manifest_versions(map, required) do
      check(:mise_manifest, :ok, "#{path} is aligned", nil)
    else
      false ->
        check(
          :mise_manifest,
          :error,
          "#{path} is missing",
          "Run `mix mom.bootstrap --cwd #{cwd}` to generate .tool-versions and mise.toml."
        )

      {:error, reason} ->
        check(
          :mise_manifest,
          :error,
          "mise.toml validation failed: #{reason}",
          "Run `mix mom.bootstrap --cwd #{cwd}` to repair toolchain manifests."
        )

      _other ->
        check(
          :mise_manifest,
          :error,
          "mise.toml validation failed",
          "Run `mix mom.bootstrap --cwd #{cwd}` to repair toolchain manifests."
        )
    end
  end

  defp validate_manifest_versions(map, required) do
    with :ok <- manifest_value_equals(map, "node", required.bootstrap_node_version),
         :ok <- manifest_value_equals(map, "erlang", required.otp_version),
         :ok <- manifest_value_equals(map, "elixir", required.bootstrap_elixir_version) do
      :ok
    end
  end

  defp manifest_value_equals(map, key, expected) do
    case Map.get(map, key) do
      ^expected -> :ok
      nil -> {:error, "missing #{key}"}
      actual -> {:error, "#{key} must be #{expected}; found #{actual}"}
    end
  end

  defp parse_tool_versions(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ~r/\s+/, trim: true) do
        [tool, version | _rest] -> Map.put(acc, tool, version)
        _ -> acc
      end
    end)
  end

  defp parse_mise_toml(body) do
    body
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^\s*([a-z_]+)\s*=\s*"([^"]+)"\s*$/, line) do
        [_full, tool, version] -> Map.put(acc, tool, version)
        _ -> acc
      end
    end)
  end

  defp tool_versions_content(node_version, otp_version, elixir_version) do
    Enum.join(
      [
        "node #{node_version}",
        "erlang #{otp_version}",
        "elixir #{elixir_version}",
        ""
      ],
      "\n"
    )
  end

  defp mise_toml_content(node_version, otp_version, elixir_version) do
    Enum.join(
      [
        "[tools]",
        ~s(node = "#{node_version}"),
        ~s(erlang = "#{otp_version}"),
        ~s(elixir = "#{elixir_version}"),
        ""
      ],
      "\n"
    )
  end

  defp required_node_major(runtime) do
    case parse_int(runtime[:required_node_major]) do
      value when is_integer(value) and value > 0 -> value
      _ -> @minimum_node_major
    end
  end

  defp required_otp_version(runtime) do
    case runtime[:required_otp_version] do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> @required_otp_version
    end
  end

  defp required_elixir_version(runtime) do
    case runtime[:required_elixir_version] do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> @required_elixir_version
    end
  end

  defp bootstrap_node_version(runtime) do
    case runtime[:bootstrap_node_version] do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> @default_bootstrap_node_version
    end
  end

  defp bootstrap_elixir_version(runtime) do
    case runtime[:bootstrap_elixir_version] do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> @default_bootstrap_elixir_version
    end
  end

  defp detect_node_version(opts, runtime) do
    case Keyword.get(opts, :toolchain_node_version_override) ||
           runtime[:toolchain_node_version_override] ||
           System.get_env("MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE") do
      nil -> run_node_version_command()
      value -> {:ok, normalize_version_string(value)}
    end
  end

  defp run_node_version_command do
    case System.cmd("node", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, normalize_version_string(output)}

      {output, status} ->
        {:error,
         "node --version failed with exit status #{status}: #{normalize_version_string(output)}"}
    end
  rescue
    _error ->
      {:error, "node executable is required and must be available in PATH"}
  end

  defp validate_node_version(version, minimum_major) do
    with {:ok, %{major: parsed_major, display_version: display_version}} <-
           parse_major_version(version, "node --version") do
      if parsed_major >= minimum_major do
        :ok
      else
        {:error, "node --version must be >= #{minimum_major}.x; found #{display_version}"}
      end
    end
  end

  defp detect_otp_version(opts, runtime) do
    case Keyword.get(opts, :toolchain_otp_version_override) ||
           runtime[:toolchain_otp_version_override] ||
           System.get_env("MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE") do
      nil -> read_otp_version_file()
      value -> {:ok, normalize_version_string(value)}
    end
  end

  defp read_otp_version_file do
    root = :code.root_dir() |> to_string()
    otp_release = :erlang.system_info(:otp_release) |> to_string()
    otp_version_path = Path.join([root, "releases", otp_release, "OTP_VERSION"])

    case File.read(otp_version_path) do
      {:ok, value} ->
        {:ok, normalize_version_string(value)}

      {:error, reason} ->
        {:error,
         "erlang/otp patch version could not be determined from #{otp_version_path}: #{inspect(reason)}"}
    end
  end

  defp validate_otp_version(actual_version, required_version) do
    if actual_version == required_version do
      :ok
    else
      {:error, "erlang/otp version must be #{required_version}; found #{actual_version}"}
    end
  end

  defp detect_elixir_version(opts, runtime) do
    case Keyword.get(opts, :toolchain_elixir_version_override) ||
           runtime[:toolchain_elixir_version_override] ||
           System.get_env("MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE") do
      nil -> {:ok, System.version()}
      value -> {:ok, normalize_version_string(value)}
    end
  end

  defp validate_elixir_version(actual_version, required_version) do
    with {:ok, required} <- Version.parse(required_version),
         {:ok, parsed} <- Version.parse(actual_version),
         true <- required.pre == [],
         true <- parsed.pre == [] do
      if parsed.major == required.major and parsed.minor == required.minor and
           parsed.patch == required.patch do
        :ok
      else
        {:error, "elixir version must be stable #{required_version}; found #{actual_version}"}
      end
    else
      _ ->
        {:error, "elixir version must be stable #{required_version}; found #{actual_version}"}
    end
  end

  defp parse_major_version(version, label) do
    version_candidate =
      version
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.find(&Regex.match?(~r/^v?\d+(?:\.\d+){1,2}$/, &1))
      |> case do
        nil -> String.trim(version)
        line -> line
      end

    case Regex.run(~r/^(v?(\d+)(?:\.\d+){1,2})$/, version_candidate) do
      [_full_match, matched_version, major] ->
        {parsed, _rest} = Integer.parse(major)
        {:ok, %{major: parsed, display_version: matched_version}}

      _ ->
        {:error, "#{label} returned an unparseable version: #{version}"}
    end
  end

  defp normalize_version_string(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end
end
