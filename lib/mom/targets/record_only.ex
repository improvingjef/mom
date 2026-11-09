defmodule Mom.Targets.RecordOnly do
  @moduledoc """
  Pipeline worker for targets with triage `off`: does nothing. The error is
  already in `Mom.Status`; no agent is called.
  """

  @spec perform(term(), keyword()) :: :ok
  def perform(_job, _opts), do: :ok
end
