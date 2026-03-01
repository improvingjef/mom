defmodule Mom.Governance.Configs.Governance do
  @moduledoc false

  alias Mom.Governance.Configs.{LLM, Merge}

  @type execution_profile :: :test_relaxed | :staging_restricted | :production_hardened
  @type sandbox_mode :: :unrestricted | :workspace_write | :read_only
  @type execution_policy :: %{
          sandbox_mode: sandbox_mode(),
          command_allowlist: [String.t()],
          write_boundaries: [String.t()]
        }
  @type gate_template_map :: %{optional(atom()) => struct()}
  @type gate_template_keyword :: [{atom(), struct()}]
  @type gate_templates :: gate_template_keyword() | gate_template_map() | nil

  defstruct [
    :execution_profile,
    :sandbox_mode,
    :command_allowlist,
    :write_boundaries,
    :open_pr,
    :merge_pr,
    :readiness_gate_approved,
    :allowed_github_repos,
    :allowed_actor_ids,
    :github_repo,
    :github_base_branch,
    :protected_branches,
    :actor_id,
    :allowed_egress_hosts,
    :branch_name_prefix,
    :governance_gates
  ]

  @type t :: %__MODULE__{
          execution_profile: execution_profile(),
          sandbox_mode: sandbox_mode(),
          command_allowlist: [String.t()],
          write_boundaries: [String.t()],
          open_pr: boolean(),
          merge_pr: boolean(),
          readiness_gate_approved: boolean(),
          allowed_github_repos: [String.t()],
          allowed_actor_ids: [String.t()],
          github_repo: String.t() | nil,
          github_base_branch: String.t(),
          protected_branches: [String.t()],
          actor_id: String.t(),
          allowed_egress_hosts: [String.t()],
          branch_name_prefix: String.t(),
          governance_gates: gate_templates()
        }

  @spec config(keyword()) :: t()
  def config(cli_opts) do
    template =
      Application.fetch_env!(:mom, :config2_defaults)
      |> Map.fetch!(:governance)

    Merge.configure(template, cli_opts, %{actor_id: "GITHUB_ACTOR"})
  end

  @spec parse_execution_profile(keyword(), keyword()) ::
          {:ok, execution_profile()} | {:error, String.t()}
  def parse_execution_profile(opts, runtime) do
    case Keyword.get(opts, :execution_profile, runtime[:execution_profile]) do
      :test_relaxed ->
        {:ok, :test_relaxed}

      :staging_restricted ->
        {:ok, :staging_restricted}

      :production_hardened ->
        {:ok, :production_hardened}

      "test_relaxed" ->
        {:ok, :test_relaxed}

      "staging_restricted" ->
        {:ok, :staging_restricted}

      "production_hardened" ->
        {:ok, :production_hardened}

      nil ->
        {:error,
         "execution_profile must be :test_relaxed, :staging_restricted, or :production_hardened"}

      _other ->
        {:error,
         "execution_profile must be :test_relaxed, :staging_restricted, or :production_hardened"}
    end
  end

  @spec parse_allowed_github_repos(keyword(), keyword()) :: {:ok, [String.t()]}
  def parse_allowed_github_repos(opts, runtime) do
    value = Keyword.get(opts, :allowed_github_repos, runtime[:allowed_github_repos])
    {:ok, normalize_csv_or_list(value)}
  end

  @spec parse_allowed_actor_ids(keyword(), keyword()) :: {:ok, [String.t()]}
  def parse_allowed_actor_ids(opts, runtime) do
    value = Keyword.get(opts, :allowed_actor_ids, runtime[:allowed_actor_ids])
    {:ok, normalize_csv_or_list(value)}
  end

  @spec parse_allowed_egress_hosts(keyword(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse_allowed_egress_hosts(opts, runtime) do
    value = Keyword.get(opts, :allowed_egress_hosts, runtime[:allowed_egress_hosts])

    hosts =
      case normalize_csv_or_list(value) do
        [] -> []
        parsed -> Enum.uniq(parsed)
      end
      |> Enum.map(&String.downcase/1)

    if Enum.all?(hosts, &valid_host?/1) do
      {:ok, hosts}
    else
      {:error, "allowed_egress_hosts must contain valid hostnames"}
    end
  end

  @spec validate_required_egress_hosts(LLM.provider(), String.t() | nil, [String.t()]) ::
          :ok | {:error, String.t()}
  def validate_required_egress_hosts(llm_provider, llm_api_url, allowed_egress_hosts) do
    with {:ok, required_llm_host} <- LLM.required_host(llm_provider, llm_api_url),
         :ok <- ensure_host_allowed("api.github.com", allowed_egress_hosts),
         :ok <- maybe_ensure_host_allowed(required_llm_host, allowed_egress_hosts) do
      :ok
    end
  end

  @spec parse_branch_name_prefix(keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_branch_name_prefix(opts, runtime) do
    prefix = Keyword.get(opts, :branch_name_prefix, runtime[:branch_name_prefix])

    if valid_branch_prefix?(prefix) do
      {:ok, prefix}
    else
      {:error, "branch_name_prefix is not a valid git branch prefix"}
    end
  end

  @spec parse_github_base_branch(keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_github_base_branch(opts, runtime) do
    base_branch = Keyword.get(opts, :github_base_branch, runtime[:github_base_branch])

    if valid_branch_prefix?(base_branch) do
      {:ok, base_branch}
    else
      {:error, "github_base_branch is not a valid git branch name"}
    end
  end

  @spec parse_protected_branches(keyword(), keyword(), String.t()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def parse_protected_branches(opts, runtime, github_base_branch) do
    parsed =
      opts
      |> Keyword.get(:protected_branches, runtime[:protected_branches])
      |> normalize_csv_or_list()
      |> case do
        [] -> [github_base_branch]
        list -> list
      end
      |> Enum.uniq()

    if Enum.all?(parsed, &valid_branch_prefix?/1) do
      {:ok, parsed}
    else
      {:error, "protected_branches must contain valid git branch names"}
    end
  end

  @spec parse_readiness_gate_approved(keyword(), keyword()) ::
          {:ok, boolean()} | {:error, String.t()}
  def parse_readiness_gate_approved(opts, runtime) do
    case Keyword.get(opts, :readiness_gate_approved, runtime[:readiness_gate_approved]) do
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, "readiness_gate_approved must be a boolean"}
    end
  end

  @spec parse_open_pr(keyword(), keyword(), keyword()) :: {:ok, boolean()} | {:error, String.t()}
  def parse_open_pr(opts, runtime, opts_for_profile) do
    default =
      case Keyword.get(opts_for_profile, :execution_profile) do
        :production_hardened -> false
        _ -> true
      end

    open_pr_default =
      case runtime[:open_pr] do
        nil -> default
        value -> value
      end

    parse_boolean_opt(opts, runtime, :open_pr, open_pr_default, "open_pr must be a boolean")
  end

  @spec parse_merge_pr(keyword(), keyword()) :: {:ok, boolean()} | {:error, String.t()}
  def parse_merge_pr(opts, runtime) do
    parse_boolean_opt(opts, runtime, :merge_pr, runtime[:merge_pr], "merge_pr must be a boolean")
  end

  @spec parse_actor_id(keyword(), keyword()) :: String.t()
  def parse_actor_id(opts, runtime) do
    case Keyword.get(opts, :actor_id) || runtime[:actor_id] do
      nil -> ""
      actor when is_binary(actor) -> String.trim(actor)
      actor -> to_string(actor) |> String.trim()
    end
  end

  @spec execution_policy(execution_profile(), String.t() | nil) :: execution_policy()
  def execution_policy(:test_relaxed, _workdir) do
    %{
      sandbox_mode: :unrestricted,
      command_allowlist: [],
      write_boundaries: []
    }
  end

  def execution_policy(:staging_restricted, workdir) do
    %{
      sandbox_mode: :workspace_write,
      command_allowlist: ["codex"],
      write_boundaries: if(is_binary(workdir), do: [workdir], else: [])
    }
  end

  def execution_policy(:production_hardened, workdir) do
    %{
      sandbox_mode: :read_only,
      command_allowlist: ["codex"],
      write_boundaries: if(is_binary(workdir), do: [workdir], else: [])
    }
  end

  @spec validate_policy_alignment(t(), map()) :: :ok | {:error, String.t()}
  def validate_policy_alignment(
        %__MODULE__{execution_profile: :staging_restricted} = governance,
        expected
      ) do
    cond do
      governance.write_boundaries != expected.write_boundaries ->
        {:error, "staging_restricted requires an isolated --workdir write boundary"}

      governance.command_allowlist != expected.command_allowlist ->
        {:error, "staging_restricted requires codex command allowlist compliance"}

      governance.sandbox_mode != expected.sandbox_mode ->
        {:error, "staging_restricted requires codex sandbox mode workspace-write"}

      true ->
        :ok
    end
  end

  def validate_policy_alignment(
        %__MODULE__{execution_profile: :production_hardened} = governance,
        expected
      ) do
    cond do
      governance.write_boundaries != expected.write_boundaries ->
        {:error, "production_hardened requires an isolated --workdir write boundary"}

      governance.command_allowlist != expected.command_allowlist ->
        {:error, "production_hardened requires codex command allowlist compliance"}

      governance.sandbox_mode != expected.sandbox_mode ->
        {:error, "production_hardened requires codex sandbox mode read-only"}

      true ->
        :ok
    end
  end

  def validate_policy_alignment(%__MODULE__{}, _expected), do: :ok

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

  defp valid_host?(host) when is_binary(host) do
    trimmed = String.trim(host)

    trimmed == host and Regex.match?(~r/^[A-Za-z0-9.-]+$/, trimmed) and
      (String.contains?(trimmed, ".") or trimmed == "localhost")
  end

  defp valid_host?(_), do: false

  defp maybe_ensure_host_allowed(nil, _allowed_hosts), do: :ok
  defp maybe_ensure_host_allowed(host, allowed_hosts), do: ensure_host_allowed(host, allowed_hosts)

  defp ensure_host_allowed(host, allowed_hosts) do
    if host in allowed_hosts do
      :ok
    else
      {:error, "allowed_egress_hosts is missing required host #{host}"}
    end
  end

  defp valid_branch_prefix?(prefix) when is_binary(prefix) do
    trimmed = String.trim(prefix)

    trimmed == prefix and
      trimmed != "" and
      Regex.match?(~r/^[0-9A-Za-z._\/-]+$/, trimmed) and
      not String.contains?(trimmed, ["..", "@{"]) and
      not String.starts_with?(trimmed, ["/", ".", "-"]) and
      not String.ends_with?(trimmed, ["/", ".", ".lock"]) and
      Enum.all?(String.split(trimmed, "/"), &valid_branch_segment?/1)
  end

  defp valid_branch_prefix?(_), do: false

  defp valid_branch_segment?(segment) do
    segment != "" and
      segment != "." and
      segment != ".." and
      not String.starts_with?(segment, ".") and
      not String.ends_with?(segment, ".lock")
  end
end
