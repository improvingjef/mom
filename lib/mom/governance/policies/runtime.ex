defmodule Mom.Governance.Policies.Runtime do
  @moduledoc false

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

  @spec validate(t()) :: :ok
  def validate(%__MODULE__{}), do: :ok
end
