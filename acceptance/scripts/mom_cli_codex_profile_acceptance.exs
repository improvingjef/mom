defmodule Mom.Acceptance.MomCLICodexProfileScript do
  def run do
    {:ok, default_config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex"
      ])

    {:ok, override_config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex",
        "--llm-cmd",
        "codex --profile staging exec"
      ])

    result = %{
      default_provider: to_string(default_config.llm_provider),
      default_llm_cmd: default_config.llm_cmd,
      override_llm_cmd: override_config.llm_cmd
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end
end

Mom.Acceptance.MomCLICodexProfileScript.run()
