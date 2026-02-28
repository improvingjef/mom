defmodule Mom.Governance.Policies.Governance do
  @moduledoc false

  @type execution_profile :: :test_relaxed | :staging_restricted | :production_hardened

  defstruct [
    :execution_profile,
    :workdir,
    :sandbox_mode,
    :command_allowlist,
    :write_boundaries,
    :open_pr,
    :merge_pr,
    :readiness_gate_approved
  ]

  @type t :: %__MODULE__{
          execution_profile: execution_profile(),
          workdir: String.t() | nil,
          sandbox_mode: :unrestricted | :workspace_write | :read_only,
          command_allowlist: [String.t()],
          write_boundaries: [String.t()],
          open_pr: boolean(),
          merge_pr: boolean(),
          readiness_gate_approved: boolean()
        }

  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{execution_profile: :test_relaxed}), do: :ok

  def validate(%__MODULE__{execution_profile: :staging_restricted} = policy) do
    expected = expected_policy(:staging_restricted, policy.workdir)

    cond do
      policy.write_boundaries != expected.write_boundaries ->
        {:error, "staging_restricted requires an isolated --workdir write boundary"}

      policy.command_allowlist != expected.command_allowlist ->
        {:error, "staging_restricted requires codex command allowlist compliance"}

      policy.sandbox_mode != expected.sandbox_mode ->
        {:error, "staging_restricted requires codex sandbox mode workspace-write"}

      true ->
        :ok
    end
  end

  def validate(%__MODULE__{execution_profile: :production_hardened} = policy) do
    expected = expected_policy(:production_hardened, policy.workdir)

    cond do
      policy.write_boundaries != expected.write_boundaries ->
        {:error, "production_hardened requires an isolated --workdir write boundary"}

      policy.command_allowlist != expected.command_allowlist ->
        {:error, "production_hardened requires codex command allowlist compliance"}

      policy.sandbox_mode != expected.sandbox_mode ->
        {:error, "production_hardened requires codex sandbox mode read-only"}

      (policy.open_pr or policy.merge_pr) and not policy.readiness_gate_approved ->
        {:error, "production_hardened requires readiness gate approval for sensitive operations"}

      true ->
        :ok
    end
  end

  defp expected_policy(:staging_restricted, workdir) do
    %{
      sandbox_mode: :workspace_write,
      command_allowlist: ["codex"],
      write_boundaries: if(is_binary(workdir), do: [workdir], else: [])
    }
  end

  defp expected_policy(:production_hardened, workdir) do
    %{
      sandbox_mode: :read_only,
      command_allowlist: ["codex"],
      write_boundaries: if(is_binary(workdir), do: [workdir], else: [])
    }
  end
end
