defmodule Mom.Governance.Policies.LLM do
  @moduledoc false

  @type provider :: :claude_code | :codex | :api_anthropic | :api_openai | :ollama
  @type execution_profile :: :test_relaxed | :staging_restricted | :production_hardened

  defstruct [
    :execution_profile,
    :provider,
    :cmd
  ]

  @type t :: %__MODULE__{
          execution_profile: execution_profile(),
          provider: provider(),
          cmd: String.t() | nil
        }

  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{execution_profile: :test_relaxed}), do: :ok

  def validate(%__MODULE__{execution_profile: :staging_restricted} = policy) do
    cond do
      policy.provider != :codex ->
        {:error, "staging_restricted currently supports llm_provider=codex only"}

      not command_binary_allowed?(policy.cmd, ["codex"]) ->
        {:error, "staging_restricted requires codex command allowlist compliance"}

      String.contains?(policy.cmd || "", "--yolo") ->
        {:error, "staging_restricted forbids --yolo execution"}

      not codex_workspace_write_sandbox?(policy.cmd) ->
        {:error, "staging_restricted requires codex sandbox mode workspace-write"}

      true ->
        :ok
    end
  end

  def validate(%__MODULE__{execution_profile: :production_hardened} = policy) do
    cond do
      policy.provider != :codex ->
        {:error, "production_hardened currently supports llm_provider=codex only"}

      not command_binary_allowed?(policy.cmd, ["codex"]) ->
        {:error, "production_hardened requires codex command allowlist compliance"}

      String.contains?(policy.cmd || "", "--yolo") ->
        {:error, "production_hardened forbids --yolo execution"}

      not codex_read_only_sandbox?(policy.cmd) ->
        {:error, "production_hardened requires codex sandbox mode read-only"}

      true ->
        :ok
    end
  end

  defp command_binary_allowed?(llm_cmd, allowlist)
       when is_binary(llm_cmd) and is_list(allowlist) do
    case String.split(llm_cmd, ~r/\s+/, trim: true) do
      [binary | _] -> binary in allowlist
      [] -> false
    end
  end

  defp command_binary_allowed?(_llm_cmd, _allowlist), do: false

  defp codex_workspace_write_sandbox?(llm_cmd) when is_binary(llm_cmd) do
    Regex.match?(~r/(^|\s)--sandbox(=|\s+)workspace-write(\s|$)/, llm_cmd)
  end

  defp codex_workspace_write_sandbox?(_llm_cmd), do: false

  defp codex_read_only_sandbox?(llm_cmd) when is_binary(llm_cmd) do
    Regex.match?(~r/(^|\s)--sandbox(=|\s+)read-only(\s|$)/, llm_cmd)
  end

  defp codex_read_only_sandbox?(_llm_cmd), do: false
end
