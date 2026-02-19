defmodule Mix.Tasks.Mom.Harness do
  use Mix.Task

  alias Mom.HarnessRepo

  @shortdoc "Confirm and record private fragile harness repository metadata"

  @moduledoc """
  Confirms a fragile harness repo is private and records its location metadata.

  Examples:
      mix mom.harness --repo owner/name --record-path acceptance/harness_repo.json \
        --baseline-error-path priv/replay/error_path.ex \
        --baseline-diagnostics-path priv/replay/diagnostics_path.ex \
        --traceability-path acceptance/harness_traceability.json
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    with {:ok, opts} <- parse_args(args),
         {:ok, record} <-
           HarnessRepo.confirm_and_record(opts.repo, opts.record_path,
             baseline_error_path: opts.baseline_error_path,
             baseline_diagnostics_path: opts.baseline_diagnostics_path,
             traceability_path: opts.traceability_path
           ) do
      Mix.shell().info(
        "recorded private harness repo: #{record.name_with_owner} -> #{opts.record_path}"
      )
    else
      {:error, reason} ->
        Mix.raise("mom.harness failed: #{reason}")
    end
  end

  @spec parse_args([String.t()]) ::
          {:ok,
           %{
             repo: String.t(),
             record_path: String.t(),
             baseline_error_path: String.t(),
             baseline_diagnostics_path: String.t(),
             traceability_path: String.t()
           }}
          | {:error, String.t()}
  def parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          repo: :string,
          record_path: :string,
          baseline_error_path: :string,
          baseline_diagnostics_path: :string,
          traceability_path: :string
        ]
      )

    repo = Keyword.get(opts, :repo)
    record_path = Keyword.get(opts, :record_path, "acceptance/harness_repo.json")
    baseline_error_path = Keyword.get(opts, :baseline_error_path)
    baseline_diagnostics_path = Keyword.get(opts, :baseline_diagnostics_path)
    traceability_path = Keyword.get(opts, :traceability_path, "acceptance/harness_traceability.json")

    cond do
      is_nil(repo) or repo == "" ->
        {:error, "--repo is required"}

      is_nil(baseline_error_path) or baseline_error_path == "" ->
        {:error, "--baseline-error-path is required"}

      is_nil(baseline_diagnostics_path) or baseline_diagnostics_path == "" ->
        {:error, "--baseline-diagnostics-path is required"}

      true ->
        {:ok,
          %{
            repo: repo,
            record_path: record_path,
            baseline_error_path: baseline_error_path,
            baseline_diagnostics_path: baseline_diagnostics_path,
            traceability_path: traceability_path
          }}
    end
  end
end
