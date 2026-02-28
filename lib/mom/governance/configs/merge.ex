defmodule Mom.Governance.Configs.Merge do
  @moduledoc false

  require Logger

  @spec configure(struct(), keyword(), map()) :: struct()
  def configure(template, cli_opts, env_key_overrides \\ %{}) when is_struct(template) do
    raw_attrs =
      template
      |> Map.from_struct()
      |> Map.keys()
      |> Enum.reduce([], fn key, acc ->
        value =
          case Keyword.fetch(cli_opts, key) do
            {:ok, cli_value} ->
              cli_value

            :error ->
              System.get_env(env_key(key, env_key_overrides))
          end

        if value in [nil, ""] do
          acc
        else
          [{key, value} | acc]
        end
      end)
      |> Enum.reverse()

    schema =
      template
      |> Map.from_struct()
      |> Enum.map(fn {key, template_value} ->
        {key, [type: schema_type(template_value)]}
      end)

    case NimbleOptions.validate(raw_attrs, schema) do
      {:ok, attrs} ->
        struct(template, attrs)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        Logger.warning("config2: invalid override ignored for #{inspect(template.__struct__)}: #{Exception.message(error)}")
        template
    end
  end

  defp env_key(field, overrides),
    do: Map.get(overrides, field, "MOM_" <> String.upcase(to_string(field)))

  defp schema_type(template) when is_boolean(template),
    do: {:custom, __MODULE__, :cast_boolean, []}

  defp schema_type(template) when is_integer(template),
    do: {:custom, __MODULE__, :cast_integer, []}

  defp schema_type(template) when is_float(template),
    do: {:custom, __MODULE__, :cast_float, []}

  defp schema_type(template) when is_atom(template),
    do: {:custom, __MODULE__, :cast_atom, []}

  defp schema_type(template) when is_binary(template),
    do: {:custom, __MODULE__, :cast_string, []}

  defp schema_type(template) when is_list(template),
    do: {:custom, __MODULE__, :cast_list, []}

  defp schema_type(_template), do: :any

  @doc false
  def cast_boolean(value) when is_boolean(value), do: {:ok, value}
  def cast_boolean("true"), do: {:ok, true}
  def cast_boolean("false"), do: {:ok, false}
  def cast_boolean(_), do: {:error, "expected boolean"}

  @doc false
  def cast_integer(value) when is_integer(value), do: {:ok, value}

  def cast_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> {:error, "expected integer"}
    end
  end

  def cast_integer(_), do: {:error, "expected integer"}

  @doc false
  def cast_float(value) when is_float(value), do: {:ok, value}
  def cast_float(value) when is_integer(value), do: {:ok, value * 1.0}

  def cast_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> {:error, "expected float"}
    end
  end

  def cast_float(_), do: {:error, "expected float"}

  @doc false
  def cast_atom(value) when is_atom(value), do: {:ok, value}

  def cast_atom(value) when is_binary(value) do
    trimmed = String.trim(value)

    try do
      {:ok, String.to_existing_atom(trimmed)}
    rescue
      ArgumentError -> {:error, "expected known atom value"}
    end
  end

  def cast_atom(_), do: {:error, "expected atom"}

  @doc false
  def cast_string(value) when is_binary(value), do: {:ok, value}
  def cast_string(value), do: {:ok, to_string(value)}

  @doc false
  def cast_list(value) when is_list(value), do: {:ok, value}

  def cast_list(value) when is_binary(value) do
    parsed =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, parsed}
  end

  def cast_list(_), do: {:error, "expected list or comma-separated string"}
end
