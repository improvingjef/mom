defmodule Mom.Governance.Policies.Diagnostics do
  @moduledoc false

  defstruct [
    :execution_profile,
    :test_command_profile
  ]

  @type t :: %__MODULE__{
          execution_profile: :test_relaxed | :staging_restricted | :production_hardened,
          test_command_profile: :mix_test | :mix_test_no_start
        }

  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{execution_profile: :test_relaxed}), do: :ok

  def validate(%__MODULE__{execution_profile: _profile, test_command_profile: :mix_test}), do: :ok

  def validate(%__MODULE__{execution_profile: profile, test_command_profile: test_profile}) do
    {:error,
     "test_command_profile #{test_profile} is not allowed for execution_profile #{profile}"}
  end
end
