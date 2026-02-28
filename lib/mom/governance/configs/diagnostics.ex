defmodule Mom.Governance.Configs.Diagnostics do
  @moduledoc false

  alias Mom.Governance.Configs.Merge

  @type test_command_profile :: :mix_test | :mix_test_no_start
  @type test_command_profile_spec :: %{
          command: String.t(),
          args: [String.t()],
          allowed_execution_profiles: [Mom.Governance.Configs.Governance.execution_profile()]
        }

  @test_command_profiles %{
    mix_test: %{
      command: "mix",
      args: ["test"],
      allowed_execution_profiles: [:test_relaxed, :staging_restricted, :production_hardened]
    },
    mix_test_no_start: %{
      command: "mix",
      args: ["test", "--no-start"],
      allowed_execution_profiles: [:test_relaxed]
    }
  }

  defstruct [
    :triage_on_diagnostics,
    :triage_mode,
    :diag_run_queue_mult,
    :diag_mem_high_bytes,
    :diag_cooldown_ms,
    :issue_rate_limit_per_hour,
    :issue_dedupe_window_ms,
    :test_spend_cap_cents_per_hour,
    :test_run_cost_cents,
    :test_command_profile
  ]

  @type t :: %__MODULE__{
          triage_on_diagnostics: boolean(),
          triage_mode: :report | :fix,
          diag_run_queue_mult: pos_integer(),
          diag_mem_high_bytes: pos_integer(),
          diag_cooldown_ms: pos_integer(),
          issue_rate_limit_per_hour: pos_integer(),
          issue_dedupe_window_ms: pos_integer(),
          test_spend_cap_cents_per_hour: pos_integer() | nil,
          test_run_cost_cents: non_neg_integer(),
          test_command_profile: test_command_profile()
        }

  @spec config(keyword()) :: t()
  def config(cli_opts) do
    template =
      Application.fetch_env!(:mom, :config2_defaults)
      |> Map.fetch!(:diagnostics)

    Merge.configure(template, cli_opts)
  end

  @spec parse_test_command_profile(keyword(), keyword()) ::
          {:ok, test_command_profile()} | {:error, String.t()}
  def parse_test_command_profile(opts, runtime) do
    profile = Keyword.get(opts, :test_command_profile, runtime[:test_command_profile])

    with {:ok, normalized} <- normalize_test_command_profile(profile),
         {:ok, _spec} <- resolve_test_command_profile(normalized) do
      {:ok, normalized}
    else
      {:error, _reason} ->
        {:error, "test_command_profile must be one of: mix_test, mix_test_no_start"}
    end
  end

  @spec validate_test_command_profile_policy(
          test_command_profile(),
          Mom.Governance.Configs.Governance.execution_profile()
        ) :: :ok | {:error, String.t()}
  def validate_test_command_profile_policy(test_command_profile, execution_profile) do
    with {:ok, spec} <- resolve_test_command_profile(test_command_profile) do
      if execution_profile in spec.allowed_execution_profiles do
        :ok
      else
        {:error,
         "test_command_profile #{test_command_profile} is not allowed for execution_profile #{execution_profile}"}
      end
    end
  end

  @spec resolve_test_command_profile(test_command_profile()) ::
          {:ok, test_command_profile_spec()}
          | {:error, String.t()}
  def resolve_test_command_profile(profile) do
    case Map.get(@test_command_profiles, profile) do
      nil -> {:error, "unknown test command profile #{profile}"}
      spec -> {:ok, spec}
    end
  end

  defp normalize_test_command_profile(profile) when is_atom(profile), do: {:ok, profile}

  defp normalize_test_command_profile(profile) when is_binary(profile) do
    case profile do
      "mix_test" -> {:ok, :mix_test}
      "mix_test_no_start" -> {:ok, :mix_test_no_start}
      _other -> {:error, :invalid_test_command_profile}
    end
  end

  defp normalize_test_command_profile(_profile), do: {:error, :invalid_test_command_profile}
end
