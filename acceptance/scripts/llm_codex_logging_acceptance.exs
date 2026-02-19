defmodule Mom.Acceptance.LLMCodexLoggingScript do
  import ExUnit.CaptureLog

  alias Mom.{Config, LLM}

  def run do
    Application.ensure_all_started(:ex_unit)
    reset_rate_limiter()

    {:ok, success_config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_provider: :codex,
        llm_cmd: "cat",
        llm_rate_limit_per_hour: 10
      )

    success_context = %{report: %{status: :ok}, issues: [], instructions: "summarize"}

    success_log =
      capture_log(fn ->
        {:ok, _text} = LLM.generate_text(success_context, success_config)
      end)

    reset_rate_limiter()

    {:ok, failure_config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_provider: :codex,
        llm_cmd: "missing-codex-command",
        llm_rate_limit_per_hour: 10
      )

    failure_context = %{event: %{message: "boom"}, instructions: "return diff"}

    failure_log =
      capture_log(fn ->
        {:error, {:llm_failed, 127, _output}} =
          LLM.generate_patch(failure_context, failure_config)
      end)

    result = %{
      saw_start_success:
        String.contains?(success_log, "mom: codex invocation started") and
          String.contains?(success_log, "cmd=cat"),
      saw_completed_success:
        String.contains?(success_log, "mom: codex invocation completed") and
          String.contains?(success_log, "outcome=ok"),
      saw_start_failure:
        String.contains?(failure_log, "mom: codex invocation started") and
          String.contains?(failure_log, "cmd=missing-codex-command"),
      saw_completed_failure:
        String.contains?(failure_log, "mom: codex invocation completed") and
          String.contains?(failure_log, "outcome=error") and
          String.contains?(failure_log, "exit_code=127")
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp reset_rate_limiter do
    case :ets.whereis(:mom_rate_limiter) do
      :undefined -> :ok
      _ -> :ets.delete(:mom_rate_limiter)
    end
  end
end

Mom.Acceptance.LLMCodexLoggingScript.run()
