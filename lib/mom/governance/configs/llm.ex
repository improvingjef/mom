defmodule Mom.Governance.Configs.LLM do
  @moduledoc false

  alias Mom.Governance.Configs.Merge

  @type provider :: :claude_code | :codex | :api_anthropic | :api_openai

  defstruct [
    :provider,
    :cmd,
    :api_key,
    :api_url,
    :model,
    :rate_limit_per_hour,
    :spend_cap_cents_per_hour,
    :call_cost_cents,
    :token_cap_per_hour,
    :tokens_per_call_estimate
  ]

  @type t :: %__MODULE__{
          provider: provider(),
          cmd: String.t() | nil,
          api_key: String.t() | nil,
          api_url: String.t() | nil,
          model: String.t() | nil,
          rate_limit_per_hour: pos_integer(),
          spend_cap_cents_per_hour: pos_integer() | nil,
          call_cost_cents: non_neg_integer(),
          token_cap_per_hour: pos_integer() | nil,
          tokens_per_call_estimate: non_neg_integer()
        }

  @spec config(keyword()) :: t()
  def config(cli_opts) do
    template =
      Application.fetch_env!(:mom, :config2_defaults)
      |> Map.fetch!(:llm)

    Merge.configure(template, cli_opts)
  end

  @spec default_cmd(provider(), String.t() | nil, atom()) :: String.t() | nil
  def default_cmd(:codex, nil, :staging_restricted), do: "codex exec --sandbox workspace-write"
  def default_cmd(:codex, nil, :production_hardened), do: "codex exec --sandbox read-only"
  def default_cmd(:codex, nil, _profile), do: "codex --yolo exec"
  def default_cmd(_provider, cmd, _profile), do: cmd

  @spec command_binary_allowed?(String.t() | nil, [String.t()]) :: boolean()
  def command_binary_allowed?(llm_cmd, allowlist)
      when is_binary(llm_cmd) and is_list(allowlist) do
    case String.split(llm_cmd, ~r/\s+/, trim: true) do
      [binary | _] -> binary in allowlist
      [] -> false
    end
  end

  def command_binary_allowed?(_llm_cmd, _allowlist), do: false

  @spec codex_workspace_write_sandbox?(String.t() | nil) :: boolean()
  def codex_workspace_write_sandbox?(llm_cmd) when is_binary(llm_cmd) do
    Regex.match?(~r/(^|\s)--sandbox(=|\s+)workspace-write(\s|$)/, llm_cmd)
  end

  def codex_workspace_write_sandbox?(_llm_cmd), do: false

  @spec codex_read_only_sandbox?(String.t() | nil) :: boolean()
  def codex_read_only_sandbox?(llm_cmd) when is_binary(llm_cmd) do
    Regex.match?(~r/(^|\s)--sandbox(=|\s+)read-only(\s|$)/, llm_cmd)
  end

  def codex_read_only_sandbox?(_llm_cmd), do: false

  @spec required_host(provider(), String.t() | nil) :: {:ok, String.t() | nil} | {:error, String.t()}
  def required_host(:api_anthropic, nil), do: {:ok, "api.anthropic.com"}
  def required_host(:api_openai, nil), do: {:ok, "api.openai.com"}
  def required_host(:api_anthropic, url), do: parse_url_host(url)
  def required_host(:api_openai, url), do: parse_url_host(url)
  def required_host(_other, nil), do: {:ok, nil}
  def required_host(_other, url), do: parse_url_host(url)

  defp parse_url_host(url) when is_binary(url) do
    uri = URI.parse(url)

    if valid_host?(uri.host) do
      {:ok, String.downcase(uri.host)}
    else
      {:error, "llm_api_url must be a valid URL with a host"}
    end
  end

  defp parse_url_host(_), do: {:error, "llm_api_url must be a valid URL with a host"}

  defp valid_host?(host) when is_binary(host) do
    trimmed = String.trim(host)
    trimmed == host and Regex.match?(~r/^[A-Za-z0-9.-]+$/, trimmed) and String.contains?(trimmed, ".")
  end

  defp valid_host?(_), do: false
end
