defmodule Mix.Tasks.Mom.BumpToolchain do
  use Mix.Task

  alias Mom.Toolchain

  @shortdoc "Bump the Mom toolchain baseline across manifests and CI pins"

  @moduledoc """
  Updates `mix.exs`, `.tool-versions`, `mise.toml`, and CI workflow toolchain pins
  in one command, then verifies parity.

  Examples:
      mix mom.bump_toolchain --elixir-version 1.19.5 --otp-version 28.1.1 --node-version 26.1.0
      mix mom.bump_toolchain --cwd /path/to/repo --elixir-version 1.19.5
  """

  @impl true
  def run(args) do
    with {:ok, opts} <- parse_args(args),
         {:ok, result} <- Toolchain.bump_baseline(opts.cwd, opts.overrides) do
      Mix.shell().info("wrote #{result.mix_exs_path}")
      Mix.shell().info("wrote #{result.tool_versions_path}")
      Mix.shell().info("wrote #{result.mise_path}")
      Enum.each(result.workflows, &Mix.shell().info("wrote #{&1}"))
      Mix.shell().info("verified toolchain parity for #{opts.cwd}")
    else
      {:error, reason} ->
        Mix.raise("mom.bump_toolchain failed: #{reason}")
    end
  end

  @spec parse_args([String.t()]) ::
          {:ok, %{cwd: String.t(), overrides: keyword()}} | {:error, String.t()}
  def parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          cwd: :string,
          node_version: :string,
          otp_version: :string,
          elixir_version: :string
        ]
      )

    defaults = Toolchain.bootstrap_defaults()

    {:ok,
     %{
       cwd: Keyword.get(opts, :cwd, "."),
       overrides: [
         node_version: Keyword.get(opts, :node_version, defaults.node_version),
         otp_version: Keyword.get(opts, :otp_version, defaults.otp_version),
         elixir_version:
           Keyword.get(
             opts,
             :elixir_version,
             defaults.elixir_version |> String.replace(~r/-otp-\d+$/, "")
           )
       ]
     }}
  end
end
