defmodule Mom.Governance.Gates.Protocols.CanaryReleaseGate do
  @moduledoc false

  alias Mom.Governance.Configs.Governance

  @enforce_keys [:enforced, :execution_profile, :artifact_path, :max_age_seconds, :attestation_signing_key]
  defstruct [
    :enforced,
    :execution_profile,
    :artifact_path,
    :max_age_seconds,
    :attestation_signing_key,
    verify_fun: &Mom.IncidentToPr.validate_recent_canary_run/1
  ]

  @type t :: %__MODULE__{
          enforced: boolean(),
          execution_profile: Governance.execution_profile(),
          artifact_path: String.t() | nil,
          max_age_seconds: pos_integer(),
          attestation_signing_key: String.t() | nil,
          verify_fun: (keyword() -> {:ok, map()} | {:error, term()})
        }

  defimpl Mom.Governance.Gates.Protocols.Gate do
    alias Mom.Governance.Gates.Result

    @impl true
    def gate(_input), do: :canary_release

    @impl true
    def evaluate(%{enforced: false}) do
      Result.allow(:canary_release, %{reason: :gate_not_enforced})
    end

    def evaluate(%{execution_profile: profile}) when profile != :production_hardened do
      Result.allow(:canary_release, %{reason: :profile_does_not_require_canary})
    end

    def evaluate(%{
          artifact_path: artifact_path,
          max_age_seconds: max_age_seconds,
          attestation_signing_key: attestation_signing_key,
          verify_fun: verify_fun
        }) do
      case verify_fun.(
             artifact_path: artifact_path,
             max_age_seconds: max_age_seconds,
             verify_attestation: true,
             attestation_signing_key: attestation_signing_key
           ) do
        {:ok, evidence} ->
          Result.allow(:canary_release, %{reason: :canary_evidence_valid, evidence: evidence})

        {:error, reason} ->
          Result.deny(
            :canary_release,
            "release gate requires recent successful incident-to-PR canary evidence with push + PR URL proof",
            %{reason_code: :incident_to_pr_canary_release_gate_failed, canary_reason: reason}
          )
      end
    end
  end
end
