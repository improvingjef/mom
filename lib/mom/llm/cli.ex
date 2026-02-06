defmodule Mom.LLM.CLI do
  @moduledoc false

  alias Mom.Config

  @spec call(String.t(), Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def call(prompt, %Config{llm_cmd: cmd}, default_cmd) do
    exec = cmd || default_cmd

    case System.cmd(exec, [], input: prompt) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:llm_failed, code, out}}
    end
  end
end
