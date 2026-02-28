defmodule Mom.Governance.Gates.Protocols.RepoAllowlistGate do
  @moduledoc false

  @enforce_keys [:github_repo, :allowed_github_repos]
  defstruct [:github_repo, :allowed_github_repos]

  @type t :: %__MODULE__{
          github_repo: String.t() | nil,
          allowed_github_repos: [String.t()]
        }
  
  defimpl Mom.Governance.Gates.Protocols.Gate do
    alias Mom.Governance.Gates.Result

    @impl true
    def gate(_input), do: :repo_allowlist

  @impl true
    def evaluate(%{github_repo: nil, allowed_github_repos: []}) do
      Result.allow(:repo_allowlist, %{reason: :github_repo_not_configured})
    end

    def evaluate(%{github_repo: nil, allowed_github_repos: _non_empty}) do
      Result.deny(
        :repo_allowlist,
        "github_repo must be set when allowed_github_repos is configured",
        %{reason_code: :repo_required_for_allowlist}
      )
    end

    def evaluate(%{github_repo: github_repo, allowed_github_repos: []}) do
      Result.allow(:repo_allowlist, %{reason: :allowlist_not_configured, github_repo: github_repo})
    end

    def evaluate(%{github_repo: github_repo, allowed_github_repos: allowed_github_repos}) do
      if github_repo in allowed_github_repos do
        Result.allow(:repo_allowlist, %{github_repo: github_repo})
      else
        Result.deny(:repo_allowlist, "github_repo is not allowed", %{
          reason_code: :repo_disallowed,
          github_repo: github_repo,
          allowed_github_repos: allowed_github_repos
        })
      end
    end
  end
end
