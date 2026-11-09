defmodule Mom.Targets do
  @moduledoc """
  The list of apps Mom watches (targets), read from configuration.

  The list is JSON, for example (from `MOM_TARGETS`):

      [{"name": "school", "node": "school@172.30.2.137", "triage": "off"},
       {"name": "latte", "node": "latte@172.30.2.120", "triage": "report",
        "agent": "claude_code"}]

  * `name` - letters, digits, `_` and `-`; unique.
  * `node` - the app's node name, `name@host`.
  * `triage` - `off` (default), `report` or `fix`. `off` records errors and
    calls no agent.
  * `agent` - `claude_code` (default) or `codex`.

  The cookie of a target comes from the environment variable
  `MOM_TARGET_COOKIE_<NAME>` (name in upper case, `-` as `_`), collected in
  `config/runtime.exs` into `config :mom, :target_cookies`. Without one, Mom
  uses its own cookie for that node.
  """

  defmodule Target do
    @moduledoc false
    @enforce_keys [:name, :node]
    defstruct [:name, :node, :cookie, triage: :off, agent: :claude_code]

    @type t :: %__MODULE__{
            name: String.t(),
            node: node(),
            cookie: atom() | nil,
            triage: :off | :report | :fix,
            agent: :claude_code | :codex
          }
  end

  @doc "Parses the JSON text (or decoded list) of targets."
  @spec parse(String.t() | list() | nil, map()) :: {:ok, [Target.t()]} | {:error, String.t()}
  def parse(json, cookies \\ %{})

  def parse(nil, _cookies), do: {:ok, []}
  def parse("", _cookies), do: {:ok, []}

  def parse(json, cookies) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} -> parse(list, cookies)
      {:error, error} -> {:error, "targets: invalid JSON: #{Exception.message(error)}"}
    end
  end

  def parse(list, cookies) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case parse_one(item, cookies) do
        {:ok, target} ->
          if Enum.any?(acc, &(&1.name == target.name)) do
            {:halt, {:error, "targets: duplicate name #{inspect(target.name)}"}}
          else
            {:cont, {:ok, [target | acc]}}
          end

        {:error, reason} ->
          {:halt, {:error, "targets[#{index}]: #{reason}"}}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  def parse(_other, _cookies), do: {:error, "targets: expected a JSON list"}

  @doc "The environment variable that holds the cookie of target `name`."
  @spec cookie_env_var(String.t()) :: String.t()
  def cookie_env_var(name) do
    "MOM_TARGET_COOKIE_" <> (name |> String.upcase() |> String.replace("-", "_"))
  end

  @doc "Collects `MOM_TARGET_COOKIE_*` variables from an env map: %{\"SCHOOL\" => cookie}."
  @spec cookies_from_env(map()) :: map()
  def cookies_from_env(env \\ System.get_env()) do
    for {"MOM_TARGET_COOKIE_" <> key, value} <- env, value != "", into: %{} do
      {key, value}
    end
  end

  @doc "The targets from application config (`:targets_json`, `:target_cookies`)."
  @spec from_config() :: {:ok, [Target.t()]} | {:error, String.t()}
  def from_config do
    parse(
      Application.get_env(:mom, :targets_json),
      Application.get_env(:mom, :target_cookies, %{})
    )
  end

  defp parse_one(%{} = item, cookies) do
    with {:ok, name} <- parse_name(item["name"]),
         {:ok, node} <- parse_node(item["node"]),
         {:ok, triage} <- parse_enum(item["triage"], "triage", ~w(off report fix), :off),
         {:ok, agent} <- parse_enum(item["agent"], "agent", ~w(claude_code codex), :claude_code) do
      cookie_key = name |> String.upcase() |> String.replace("-", "_")

      cookie =
        case Map.get(cookies, cookie_key) do
          value when is_binary(value) and value != "" -> String.to_atom(value)
          _ -> nil
        end

      {:ok, %Target{name: name, node: node, cookie: cookie, triage: triage, agent: agent}}
    end
  end

  defp parse_one(_item, _cookies), do: {:error, "expected an object"}

  defp parse_name(name) when is_binary(name) do
    if Regex.match?(~r/^[A-Za-z0-9_-]{1,40}$/, name),
      do: {:ok, name},
      else: {:error, "invalid name #{inspect(name)}"}
  end

  defp parse_name(other), do: {:error, "name is required, got #{inspect(other)}"}

  defp parse_node(node) when is_binary(node) do
    case String.split(node, "@") do
      [short, host] when short != "" and host != "" -> {:ok, String.to_atom(node)}
      _ -> {:error, "node must be name@host, got #{inspect(node)}"}
    end
  end

  defp parse_node(other), do: {:error, "node is required, got #{inspect(other)}"}

  defp parse_enum(nil, _field, _allowed, default), do: {:ok, default}

  defp parse_enum(value, field, allowed, _default) when is_binary(value) do
    if value in allowed,
      do: {:ok, String.to_atom(value)},
      else: {:error, "#{field} must be one of #{Enum.join(allowed, "|")}, got #{inspect(value)}"}
  end

  defp parse_enum(value, field, _allowed, _default),
    do: {:error, "#{field} must be a string, got #{inspect(value)}"}
end
