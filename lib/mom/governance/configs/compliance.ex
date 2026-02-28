defmodule Mom.Governance.Configs.Compliance do
  @moduledoc false

  alias Mom.Audit
  alias Mom.Governance.Configs.Merge

  @required_github_credential_scopes ["contents", "pull_requests", "issues"]

  defstruct [
    :audit_retention_days,
    :soc2_evidence_path,
    :pii_handling_policy,
    :redact_keys,
    :git_ssh_command,
    :github_token,
    :github_credential_scopes,
    :github_live_permission_verification
  ]

  @type t :: %__MODULE__{
          audit_retention_days: pos_integer(),
          soc2_evidence_path: String.t() | nil,
          pii_handling_policy: :redact | :drop,
          redact_keys: [String.t()],
          git_ssh_command: String.t() | nil,
          github_token: String.t() | nil,
          github_credential_scopes: [String.t()],
          github_live_permission_verification: boolean()
        }

  @spec config(keyword()) :: t()
  def config(cli_opts) do
    template =
      Application.fetch_env!(:mom, :config2_defaults)
      |> Map.fetch!(:compliance)

    Merge.configure(template, cli_opts)
  end

  @spec normalize_redact_keys(nil | [term()] | String.t()) :: [String.t()]
  def normalize_redact_keys(nil), do: default_redact_keys()
  def normalize_redact_keys(keys) when is_list(keys), do: Enum.map(keys, &to_string/1)

  def normalize_redact_keys(keys) when is_binary(keys) do
    keys
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default_redact_keys()
      list -> list
    end
  end

  @spec parse_soc2_evidence_path(keyword(), keyword()) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def parse_soc2_evidence_path(opts, runtime) do
    case Keyword.get(opts, :soc2_evidence_path, runtime[:soc2_evidence_path]) do
      nil ->
        {:ok, nil}

      path when is_binary(path) ->
        trimmed = String.trim(path)

        if trimmed == "",
          do: {:error, "soc2_evidence_path must be nil or a non-empty string"},
          else: {:ok, trimmed}

      _other ->
        {:error, "soc2_evidence_path must be nil or a non-empty string"}
    end
  end

  @spec parse_pii_handling_policy(keyword(), keyword()) ::
          {:ok, :redact | :drop} | {:error, String.t()}
  def parse_pii_handling_policy(opts, runtime) do
    case Keyword.get(opts, :pii_handling_policy, runtime[:pii_handling_policy]) do
      :redact -> {:ok, :redact}
      :drop -> {:ok, :drop}
      "redact" -> {:ok, :redact}
      "drop" -> {:ok, :drop}
      nil -> {:error, "pii_handling_policy must be :redact or :drop"}
      _other -> {:error, "pii_handling_policy must be :redact or :drop"}
    end
  end

  @spec parse_github_credential_scopes(keyword(), keyword()) :: {:ok, [String.t()]}
  def parse_github_credential_scopes(opts, runtime) do
    value =
      Keyword.get(opts, :github_credential_scopes) ||
        runtime[:github_credential_scopes]

    scopes =
      value
      |> normalize_csv_or_list()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    {:ok, scopes}
  end

  @spec parse_github_live_permission_verification(keyword(), keyword()) ::
          {:ok, boolean()} | {:error, String.t()}
  def parse_github_live_permission_verification(opts, runtime) do
    parse_boolean_opt(
      opts,
      runtime,
      :github_live_permission_verification,
      runtime[:github_live_permission_verification],
      "github_live_permission_verification must be a boolean"
    )
  end

  @spec validate_declared_github_credential_scopes([String.t()], String.t(), String.t() | nil) ::
          :ok | {:error, String.t()}
  def validate_declared_github_credential_scopes(scopes, actor_id, github_repo) do
    missing_scopes = @required_github_credential_scopes -- scopes

    if missing_scopes == [] do
      :ok
    else
      :ok =
        Audit.emit(:github_credential_scope_blocked, %{
          repo: github_repo,
          actor_id: actor_id,
          required_scopes: @required_github_credential_scopes,
          provided_scopes: scopes,
          missing_scopes: missing_scopes
        })

      {:error, "github credential scopes must include: contents, pull_requests, issues"}
    end
  end

  @spec required_github_credential_scopes() :: [String.t()]
  def required_github_credential_scopes, do: @required_github_credential_scopes

  defp default_redact_keys do
    [
      "password",
      "passwd",
      "secret",
      "token",
      "api_key",
      "apikey",
      "authorization",
      "cookie"
    ]
  end

  defp normalize_csv_or_list(nil), do: []
  defp normalize_csv_or_list([]), do: []

  defp normalize_csv_or_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_csv_or_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_csv_or_list(_), do: []

  defp parse_boolean_opt(opts, runtime, key, default, error_message) do
    case Keyword.get(opts, key, runtime[key]) do
      nil -> {:ok, default}
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, error_message}
    end
  end
end
