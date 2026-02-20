defmodule Mix.Tasks.Mom.Bootstrap do
  use Mix.Task

  alias Mom.Toolchain

  @shortdoc "Generate local toolchain manifests for asdf/mise"

  @moduledoc """
  Writes `.tool-versions` and `mise.toml` aligned to the supported Mom toolchain.

  Examples:
      mix mom.bootstrap
      mix mom.bootstrap --cwd /path/to/repo
      mix mom.bootstrap --node-version 24.6.0 --otp-version 28.0.2 --elixir-version 1.19.4-otp-28
  """

  @impl true
  def run(args) do
    with {:ok, opts} <- parse_args(args),
         {:ok, result} <- Toolchain.bootstrap(opts.cwd, opts.overrides) do
      Mix.shell().info("wrote #{result.tool_versions_path}")
      Mix.shell().info("wrote #{result.mise_path}")
      Mix.shell().info("run `mix mom.doctor --cwd #{opts.cwd}` to verify your local setup")
    else
      {:error, reason} ->
        Mix.raise("mom.bootstrap failed: #{inspect(reason)}")
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
         elixir_version: Keyword.get(opts, :elixir_version, defaults.elixir_version)
       ]
     }}
  end
end
