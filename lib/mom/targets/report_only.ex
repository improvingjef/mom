defmodule Mom.Targets.ReportOnly do
  @moduledoc """
  The engine for targets with triage `report`: an error gets an issue and a
  diagnosis from the agent, never a fix (`Mom.Engine.report_log/2`).
  Diagnostics go to `Mom.Engine.handle_diagnostics/3`, which already
  respects the target's `report` mode. `mix mom` keeps `Mom.Engine`.
  """

  @spec handle_log(map(), Mom.Config.t()) :: :ok
  def handle_log(event, config), do: Mom.Engine.report_log(event, config)

  @spec handle_diagnostics(map(), list(), Mom.Config.t()) :: :ok
  def handle_diagnostics(report, issues, config),
    do: Mom.Engine.handle_diagnostics(report, issues, config)
end
