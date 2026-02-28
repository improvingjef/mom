defmodule Mom.Governance.Configs.Runtime do
  @moduledoc false

  alias Mom.Governance.Configs.Merge

  defstruct [
    :repo,
    :node,
    :cookie,
    :mode,
    :workdir,
    :poll_interval_ms,
    :min_level,
    :dry_run
  ]

  @type t :: %__MODULE__{
          repo: String.t(),
          node: node() | nil,
          cookie: atom() | nil,
          mode: :remote | :inproc,
          workdir: String.t() | nil,
          poll_interval_ms: non_neg_integer(),
          min_level: :error | :warning | :info,
          dry_run: boolean()
        }

  @spec config(keyword()) :: t()
  def config(cli_opts) do
    template =
      Application.fetch_env!(:mom, :config2_defaults)
      |> Map.fetch!(:runtime)

    Merge.configure(template, cli_opts)
  end
end
