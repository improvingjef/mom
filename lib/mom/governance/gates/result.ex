defmodule Mom.Governance.Gates.Result do
  @moduledoc false

  @enforce_keys [:gate, :status]
  defstruct [:gate, :status, :reason, details: %{}]

  @type status :: :allow | :deny

  @type t :: %__MODULE__{
          gate: atom(),
          status: status(),
          reason: String.t() | nil,
          details: map()
        }

  @spec allow(atom(), map()) :: t()
  def allow(gate, details \\ %{}) when is_atom(gate) and is_map(details) do
    %__MODULE__{gate: gate, status: :allow, details: details}
  end

  @spec deny(atom(), String.t(), map()) :: t()
  def deny(gate, reason, details \\ %{})
      when is_atom(gate) and is_binary(reason) and is_map(details) do
    %__MODULE__{gate: gate, status: :deny, reason: reason, details: details}
  end
end

