defmodule Mom.LLM do
  @moduledoc false

  alias Mom.{Config, LLM.API, LLM.CLI, RateLimiter, SpendLimiter}

  require Logger

  @spec generate_patch(map(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_patch(context, %Config{llm: %{provider: provider}} = config) do
    prompt = build_prompt(context)

    with :ok <- Config.validate_runtime_policy(config),
         true <- RateLimiter.allow?(:llm, config.llm.rate_limit_per_hour, 3_600_000),
         :ok <- enforce_llm_budget(config) do
      call_provider(prompt, provider, config)
    else
      {:error, reason} ->
        Logger.warning("mom: llm invocation blocked by runtime policy violation reason=#{reason}")
        {:error, {:policy_violation, reason}}

      false ->
        {:error, :llm_rate_limited}

      {:budget_error, reason} ->
        {:error, reason}
    end
  end

  @spec generate_text(map(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_text(context, %Config{llm: %{provider: provider}} = config) do
    prompt = build_prompt(context)

    with :ok <- Config.validate_runtime_policy(config),
         true <- RateLimiter.allow?(:llm, config.llm.rate_limit_per_hour, 3_600_000),
         :ok <- enforce_llm_budget(config) do
      call_provider(prompt, provider, config)
    else
      {:error, reason} ->
        Logger.warning("mom: llm invocation blocked by runtime policy violation reason=#{reason}")
        {:error, {:policy_violation, reason}}

      false ->
        {:error, :llm_rate_limited}

      {:budget_error, reason} ->
        {:error, reason}
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
      :codex -> call_codex(prompt, config)
      :claude_code -> CLI.call(prompt, config, "claude")
      :api_anthropic -> API.call_anthropic(prompt, config)
      :api_openai -> API.call_openai(prompt, config)
    end
  end

  defp call_codex(prompt, %Config{} = config) do
    cmd = config.llm.cmd || "codex --yolo exec"
    started_at = System.monotonic_time()
    Logger.info("mom: codex invocation started cmd=#{cmd}")

    result = CLI.call(prompt, config, "codex --yolo exec")

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    case result do
      {:ok, _out} ->
        Logger.info("mom: codex invocation completed outcome=ok duration_ms=#{duration_ms}")

      {:error, {:llm_failed, code, _out}} ->
        Logger.warning(
          "mom: codex invocation completed outcome=error duration_ms=#{duration_ms} exit_code=#{inspect(code)}"
        )

      {:error, reason} ->
        Logger.warning(
          "mom: codex invocation completed outcome=error duration_ms=#{duration_ms} reason=#{inspect(reason)}"
        )
    end

    result
  end

  defp enforce_llm_budget(%Config{} = config) do
    case SpendLimiter.allow_spend?(
           config.runtime.repo,
           :llm_cost,
           config.llm.call_cost_cents,
           config.llm.spend_cap_cents_per_hour
         ) do
      true ->
        case SpendLimiter.allow_spend?(
               config.runtime.repo,
               :llm_tokens,
               config.llm.tokens_per_call_estimate,
               config.llm.token_cap_per_hour
             ) do
          true -> :ok
          false -> {:budget_error, :llm_token_cap_exceeded}
        end

      false ->
        {:budget_error, :llm_spend_cap_exceeded}
    end
  end
end
