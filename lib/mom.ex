defmodule Mom do
  @moduledoc """
  Entry points for Mom.
  """

  alias Mom.{Config, Runner}

  @type start_result :: {:ok, pid()} | {:error, term()}

  @spec start(Config.t()) :: start_result()
  def start(%Config{} = config) do
    Runner.start(config)
  end

  @doc """
  Directory for the service's files (tokens, target checkouts):
  `config :mom, :data_dir`, else `$RELEASE_ROOT/var` in a release, else
  `<tmp>/mom`.
  """
  @spec data_dir() :: String.t()
  def data_dir do
    Application.get_env(:mom, :data_dir) ||
      case System.get_env("RELEASE_ROOT") do
        nil -> Path.join(System.tmp_dir!(), "mom")
        root -> Path.join(root, "var")
      end
  end
end
