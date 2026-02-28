defmodule Mom.Governance.Policies.Compliance do
  @moduledoc false

  @required_github_credential_scopes ["contents", "pull_requests", "issues"]

  defstruct [
    :github_token,
    :github_repo,
    :github_credential_scopes,
    :github_live_permission_verification,
    :startup_attestation_signing_key,
    :open_pr,
    :merge_pr
  ]

  @type t :: %__MODULE__{
          github_token: String.t() | nil,
          github_repo: String.t() | nil,
          github_credential_scopes: [String.t()],
          github_live_permission_verification: boolean(),
          startup_attestation_signing_key: String.t() | nil,
          open_pr: boolean(),
          merge_pr: boolean()
        }

  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = policy) do
    credential_flow? =
      present?(policy.github_token) and present?(policy.github_repo) and
        (policy.open_pr or policy.merge_pr)

    cond do
      not credential_flow? ->
        :ok

      policy.github_live_permission_verification and not present?(policy.startup_attestation_signing_key) ->
        {:error, "startup_attestation_signing_key is required for live github permission verification"}

      policy.github_live_permission_verification ->
        :ok

      true ->
        missing = @required_github_credential_scopes -- policy.github_credential_scopes

        if missing == [] do
          :ok
        else
          {:error, "github credential scopes must include: contents, pull_requests, issues"}
        end
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
