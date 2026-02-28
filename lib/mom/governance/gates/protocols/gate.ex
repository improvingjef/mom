defprotocol Mom.Governance.Gates.Protocols.Gate do
  @moduledoc false

  alias Mom.Governance.Gates.Result

  @spec gate(t()) :: atom()
  def gate(input)

  @spec evaluate(t()) :: Result.t()
  def evaluate(input)
end

