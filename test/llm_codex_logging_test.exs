defmodule Mom.LLMCodexLoggingTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Mom.{Config, LLM}

  setup do
    Mom.TestHelper.reset_rate_limiter()
    :ok
  end

  test "logs codex invocation start and successful outcome" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_provider: :codex,
        llm_cmd: "cat",
        llm_rate_limit_per_hour: 10
      )

    context = %{report: %{status: :ok}, issues: [], instructions: "summarize"}

    log =
      capture_log(fn ->
        assert {:ok, _text} = LLM.generate_text(context, config)
      end)

    assert log =~ "mom: codex invocation started"
    assert log =~ "cmd=cat"
    assert log =~ "mom: codex invocation completed"
    assert log =~ "outcome=ok"
  end

  test "logs codex invocation start and failed outcome" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_provider: :codex,
        llm_cmd: "missing-codex-command",
        llm_rate_limit_per_hour: 10
      )

    context = %{event: %{message: "boom"}, instructions: "return diff"}

    log =
      capture_log(fn ->
        assert {:error, {:llm_failed, 127, _output}} = LLM.generate_patch(context, config)
      end)

    assert log =~ "mom: codex invocation started"
    assert log =~ "cmd=missing-codex-command"
    assert log =~ "mom: codex invocation completed"
    assert log =~ "outcome=error"
    assert log =~ "exit_code=127"
  end
end
