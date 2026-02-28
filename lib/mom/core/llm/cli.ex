defmodule Mom.LLM.CLI do
  @moduledoc false

  alias Mom.Config

  @spec call(String.t(), Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def call(prompt, %Config{llm: %{cmd: cmd}}, default_cmd) do
    exec = cmd || default_cmd

    script = """
    cat <<'MOM_PROMPT_EOF' | #{exec}
    #{prompt}
    MOM_PROMPT_EOF
    """

    case System.cmd("/bin/sh", ["-lc", script], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:llm_failed, code, out}}
    end
  end
end
