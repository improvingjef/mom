defmodule Mom.Governance.Gates.Protocols.ReadinessGate do
  @moduledoc false

  alias Mom.Governance.Configs.Governance

  @enforce_keys [:enforced, :open_pr, :readiness_gate_approved]
  defstruct [:enforced, :open_pr, :readiness_gate_approved, :execution_profile, :github_base_branch, :protected_branches]

  @type t :: %__MODULE__{
          enforced: boolean(),
          open_pr: boolean(),
          readiness_gate_approved: boolean(),
          execution_profile: Governance.execution_profile() | nil,
          github_base_branch: String.t() | nil,
          protected_branches: [String.t()] | nil
        }
  
  defimpl Mom.Governance.Gates.Protocols.Gate do
    alias Mom.Governance.Gates.Result

    @impl true
    def gate(_input), do: :readiness

    @impl true
    def evaluate(%{enforced: false}) do
      Result.allow(:readiness, %{reason: :gate_not_enforced})
    end

    def evaluate(%{open_pr: false}) do
      Result.allow(:readiness, %{reason: :open_pr_disabled})
    end

    def evaluate(%{
          enforced: true,
          open_pr: true,
          readiness_gate_approved: false
        }) do
      Result.deny(:readiness, "readiness_gate_approved must be true before enabling automated PR creation", %{
        reason_code: :readiness_gate_not_approved
      })
    end

    def evaluate(%{
          enforced: true,
          open_pr: true,
          readiness_gate_approved: true,
          github_base_branch: github_base_branch,
          protected_branches: protected_branches
        })
        when is_binary(github_base_branch) and is_list(protected_branches) do
      if github_base_branch in protected_branches do
        Result.allow(:readiness, %{
          open_pr: true,
          readiness_gate_approved: true,
          github_base_branch: github_base_branch
        })
      else
        Result.deny(:readiness, "github_base_branch must be included in protected_branches", %{
          reason_code: :base_branch_not_protected
        })
      end
    end

    def evaluate(%{open_pr: true, readiness_gate_approved: true} = input) do
      Result.allow(:readiness, %{
        open_pr: input.open_pr,
        readiness_gate_approved: input.readiness_gate_approved,
        execution_profile: input.execution_profile
      })
    end

    def evaluate(_input) do
      Result.allow(:readiness, %{reason: :no_constraints_triggered})
    end
  end
end
