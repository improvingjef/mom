defmodule Mix.Tasks.Mom.Runbook do
  use Mix.Task

  alias Mom.Runbook

  @shortdoc "Generate and validate Mom disaster recovery runbook"

  @moduledoc """
  Generates a disaster recovery runbook that includes backup/restore,
  credential revocation drill, and failover procedures.

  Examples:
      mix mom.runbook
      mix mom.runbook --output docs/disaster_recovery_runbook.md --generated-on 2026-02-19
  """

  @default_output "docs/disaster_recovery_runbook.md"

  @impl true
  def run(args) do
    with {:ok, opts} <- parse_args(args),
         markdown <- Runbook.render(opts.generated_on),
         :ok <- Runbook.validate(markdown),
         :ok <- File.mkdir_p(Path.dirname(opts.output)),
         :ok <- File.write(opts.output, markdown) do
      Mix.shell().info("wrote disaster recovery runbook: #{opts.output}")
    else
      {:error, reason} when is_binary(reason) ->
        Mix.raise("mom.runbook failed: #{reason}")

      {:error, missing} when is_list(missing) ->
        Mix.raise("mom.runbook failed: missing required sections #{inspect(missing)}")

      {:error, reason} ->
        Mix.raise("mom.runbook failed: #{inspect(reason)}")
    end
  end

  @spec parse_args([String.t()]) ::
          {:ok, %{output: String.t(), generated_on: String.t()}} | {:error, String.t()}
  def parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          generated_on: :string
        ]
      )

    output = Keyword.get(opts, :output, @default_output)
    generated_on = Keyword.get(opts, :generated_on, Date.utc_today() |> Date.to_iso8601())

    cond do
      output == "" ->
        {:error, "--output cannot be empty"}

      generated_on == "" ->
        {:error, "--generated-on cannot be empty"}

      true ->
        {:ok, %{output: output, generated_on: generated_on}}
    end
  end
end
