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
end
