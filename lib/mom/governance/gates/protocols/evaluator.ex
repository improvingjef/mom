defmodule Mom.Governance.Gates.Protocols.Evaluator do
  @moduledoc false

  alias Mom.Governance.Gates.Protocols.Gate
  alias Mom.Governance.Gates.Result

  @spec evaluate(struct()) :: Result.t()
  def evaluate(input) when is_struct(input) do
    Gate.evaluate(input)
  end

  @spec evaluate_all([struct()]) :: [Result.t()]
  def evaluate_all(inputs) when is_list(inputs) do
    Enum.map(inputs, &evaluate/1)
  end

  @spec all_allowed?([Result.t()]) :: boolean()
  def all_allowed?(results) when is_list(results) do
    Enum.all?(results, &match?(%Result{status: :allow}, &1))
  end
end

