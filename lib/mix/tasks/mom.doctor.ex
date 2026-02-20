defmodule Mix.Tasks.Mom.Doctor do
  use Mix.Task

  alias Mom.Toolchain

  @shortdoc "Run local toolchain preflight checks with actionable remediation"

  @moduledoc """
  Validates local Node.js, Erlang/OTP, Elixir, and toolchain manifest alignment
  for `mom` development.

  Examples:
      mix mom.doctor
      mix mom.doctor --format json --fail-on-error
      mix mom.doctor --cwd /path/to/repo
  """

  @impl true
  def run(args) do
    with {:ok, opts} <- parse_args(args) do
      report = Toolchain.doctor(opts.cwd)
      emit_report(report, opts.format)

      if opts.fail_on_error and report.status == "error" do
        Mix.raise("mom.doctor found toolchain preflight issues")
      end
    else
      {:error, reason} ->
        Mix.raise("mom.doctor failed: #{reason}")
    end
  end

  @spec parse_args([String.t()]) ::
          {:ok, %{format: :text | :json, cwd: String.t(), fail_on_error: boolean()}}
          | {:error, String.t()}
  def parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          format: :string,
          cwd: :string,
          fail_on_error: :boolean
        ]
      )

    with {:ok, format} <- parse_format(Keyword.get(opts, :format, "text")) do
      {:ok,
       %{
         format: format,
         cwd: Keyword.get(opts, :cwd, "."),
         fail_on_error: Keyword.get(opts, :fail_on_error, false)
       }}
    end
  end

  defp parse_format("text"), do: {:ok, :text}
  defp parse_format("json"), do: {:ok, :json}
  defp parse_format(_other), do: {:error, "--format must be one of: text, json"}

  defp emit_report(report, :json) do
    IO.puts(Jason.encode!(report))
  end

  defp emit_report(report, :text) do
    Mix.shell().info("Toolchain doctor status: #{report.status}")

    Enum.each(report.checks, fn check ->
      Mix.shell().info("[#{String.upcase(check.status)}] #{check.id}: #{check.message}")

      if check.status == "error" and is_binary(check.remediation) do
        Mix.shell().info("  remediation: #{check.remediation}")
      end
    end)
  end
end
