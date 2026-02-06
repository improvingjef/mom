defmodule Mom.LLMRateLimitTest do
  use ExUnit.Case

  alias Mom.{Config, LLM}

  setup do
    Mom.TestHelper.reset_rate_limiter()
    :ok
  end

  test "rate limits LLM calls" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_provider: :api_openai,
        llm_rate_limit_per_hour: 1
      )

    context = %{report: %{}, issues: [], instructions: "say ok"}

    assert {:error, _} = LLM.generate_text(context, config)
    assert {:error, :llm_rate_limited} = LLM.generate_text(context, config)
  end

  test "rate limits patch generation" do
    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_provider: :api_openai,
        llm_rate_limit_per_hour: 1
      )

    context = %{event: %{}, instructions: "return diff"}

    assert {:error, _} = LLM.generate_patch(context, config)
    assert {:error, :llm_rate_limited} = LLM.generate_patch(context, config)
  end
end
