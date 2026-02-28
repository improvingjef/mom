defmodule Mom.Config2 do
  @moduledoc false

  alias Mom.Governance.Policies.{
    Compliance,
    Diagnostics,
    Governance,
    LLM,
    Observability,
    Pipeline,
    Runtime
  }

  defstruct [
    :runtime,
    :llm,
    :diagnostics,
    :pipeline,
    :governance,
    :compliance,
    :observability
  ]

  @type t :: %__MODULE__{
          runtime: Runtime.t(),
          llm: LLM.t(),
          diagnostics: Diagnostics.t(),
          pipeline: Pipeline.t(),
          governance: Governance.t(),
          compliance: Compliance.t(),
          observability: Observability.t()
        }

  @spec from_opts(keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_opts(opts) do
    modules = Application.get_env(:mom, :config2_policy_modules, default_policy_modules())
    defaults = Application.fetch_env!(:mom, :config2_policy_defaults)

    with {:ok, assembled} <- build_policies(modules, defaults, opts) do
      if blank?(assembled.runtime.repo), do: {:error, "repo is required"}, else: {:ok, assembled}
    end
  end

  defp build_policies(modules, defaults, opts) do
    Enum.reduce_while(modules, {:ok, %__MODULE__{}}, fn module, {:ok, acc} ->
      with {:ok, key} <- policy_key(module),
           {:ok, template} <- fetch_policy_template(defaults, key),
           true <- is_struct(template),
           policy <- struct(template, policy_cli_attrs(template, opts)),
           :ok <- validate_policy(module, policy),
           {:ok, next} <- put_policy_struct(acc, policy) do
        {:cont, {:ok, next}}
      else
        {:error, reason} ->
          {:halt, {:error, reason}}

        false ->
          {:halt, {:error, "runtime policy default for #{inspect(module)} must be a struct"}}
      end
    end)
  end

  defp policy_cli_attrs(template, opts) do
    allowed_keys =
      template
      |> Map.from_struct()
      |> Map.keys()

    opts
    |> Enum.into(%{})
    |> Map.take(allowed_keys)
  end

  defp validate_policy(module, policy) do
    if function_exported?(module, :validate, 1) do
      module.validate(policy)
    else
      :ok
    end
  end

  defp fetch_policy_template(defaults, key) do
    case Map.fetch(defaults, key) do
      {:ok, template} -> {:ok, template}
      :error -> {:error, "missing runtime policy default #{key}"}
    end
  end

  defp put_policy_struct(%__MODULE__{} = config, %Runtime{} = value),
    do: {:ok, %{config | runtime: value}}

  defp put_policy_struct(%__MODULE__{} = config, %LLM{} = value), do: {:ok, %{config | llm: value}}

  defp put_policy_struct(%__MODULE__{} = config, %Diagnostics{} = value),
    do: {:ok, %{config | diagnostics: value}}

  defp put_policy_struct(%__MODULE__{} = config, %Pipeline{} = value),
    do: {:ok, %{config | pipeline: value}}

  defp put_policy_struct(%__MODULE__{} = config, %Governance{} = value),
    do: {:ok, %{config | governance: value}}

  defp put_policy_struct(%__MODULE__{} = config, %Compliance{} = value),
    do: {:ok, %{config | compliance: value}}

  defp put_policy_struct(%__MODULE__{} = config, %Observability{} = value),
    do: {:ok, %{config | observability: value}}

  defp put_policy_struct(_config, other),
    do: {:error, "unsupported policy struct returned: #{inspect(other.__struct__)}"}

  defp policy_key(Runtime), do: {:ok, :runtime}
  defp policy_key(LLM), do: {:ok, :llm}
  defp policy_key(Diagnostics), do: {:ok, :diagnostics}
  defp policy_key(Pipeline), do: {:ok, :pipeline}
  defp policy_key(Governance), do: {:ok, :governance}
  defp policy_key(Compliance), do: {:ok, :compliance}
  defp policy_key(Observability), do: {:ok, :observability}
  defp policy_key(module), do: {:error, "unsupported policy module #{inspect(module)}"}

  defp default_policy_modules do
    [Runtime, LLM, Diagnostics, Pipeline, Governance, Compliance, Observability]
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)
end
