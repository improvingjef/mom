defmodule Mom.LLM do
  @moduledoc false

  alias Mom.{Config, LLM.API, LLM.CLI, RateLimiter}

  @spec generate_patch(map(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_patch(context, %Config{llm_provider: provider} = config) do
    prompt = build_prompt(context)

    with true <- RateLimiter.allow?(:llm, config.llm_rate_limit_per_hour, 3_600_000) do
      call_provider(prompt, provider, config)
    else
      false -> {:error, :llm_rate_limited}
    end
  end

  @spec generate_text(map(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_text(context, %Config{llm_provider: provider} = config) do
    prompt = build_prompt(context)

    with true <- RateLimiter.allow?(:llm, config.llm_rate_limit_per_hour, 3_600_000) do
      call_provider(prompt, provider, config)
    else
      false -> {:error, :llm_rate_limited}
    end
  end

  defp build_prompt(%{event: event, instructions: instructions}) do
    """
    You are fixing a BEAM production error.

    Error event:
    #{inspect(event, pretty: true, limit: :infinity)}

    Instructions:
    #{instructions}
    """
  end

  defp build_prompt(%{report: report, issues: issues, instructions: instructions} = context) do
    """
    You are diagnosing a BEAM system issue.

    Diagnostics report:
    #{inspect(report, pretty: true, limit: :infinity)}

    Issues:
    #{inspect(issues, pretty: true, limit: :infinity)}

    Hot processes:
    #{inspect(Map.get(context, :hot_processes, []), pretty: true, limit: :infinity)}

    Instructions:
    #{instructions}
    """
  end

  defp call_provider(prompt, provider, config) do
    case provider do
      :claude_code -> CLI.call(prompt, config, "claude")
      :codex -> CLI.call(prompt, config, "codex")
      :api_anthropic -> API.call_anthropic(prompt, config)
      :api_openai -> API.call_openai(prompt, config)
    end
  end
end
