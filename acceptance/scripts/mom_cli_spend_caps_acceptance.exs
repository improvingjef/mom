defmodule Mom.Acceptance.MomCliSpendCapsScript do
  alias Mom.{Config, Git, LLM}

  def run do
    {:ok, parsed} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm-spend-cap-cents-per-hour",
        "500",
        "--llm-call-cost-cents",
        "25",
        "--llm-token-cap-per-hour",
        "20000",
        "--llm-tokens-per-call-estimate",
        "1500",
        "--test-spend-cap-cents-per-hour",
        "750",
        "--test-run-cost-cents",
        "30"
      ])

    llm_repo = "/tmp/mom-spend-llm-#{System.unique_integer([:positive])}"

    {:ok, llm_config} =
      Config.from_opts(
        repo: llm_repo,
        llm_provider: :api_openai,
        llm_spend_cap_cents_per_hour: 1,
        llm_call_cost_cents: 1,
        llm_token_cap_per_hour: 10_000,
        llm_tokens_per_call_estimate: 100
      )

    llm_context = %{report: %{}, issues: [], instructions: "say ok"}
    llm_first = normalize(LLM.generate_text(llm_context, llm_config))
    llm_second = normalize(LLM.generate_text(llm_context, llm_config))

    test_repo = create_test_repo()

    {:ok, test_config} =
      Config.from_opts(
        repo: test_repo,
        test_spend_cap_cents_per_hour: 1,
        test_run_cost_cents: 1
      )

    test_first = normalize(Git.run_tests(test_repo, test_config))
    test_second = normalize(Git.run_tests(test_repo, test_config))

    result = %{
      parsed_llm_spend_cap_cents_per_hour: parsed.llm_spend_cap_cents_per_hour,
      parsed_llm_call_cost_cents: parsed.llm_call_cost_cents,
      parsed_llm_token_cap_per_hour: parsed.llm_token_cap_per_hour,
      parsed_llm_tokens_per_call_estimate: parsed.llm_tokens_per_call_estimate,
      parsed_test_spend_cap_cents_per_hour: parsed.test_spend_cap_cents_per_hour,
      parsed_test_run_cost_cents: parsed.test_run_cost_cents,
      llm_first: llm_first,
      llm_second: llm_second,
      test_first: test_first,
      test_second: test_second
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  end

  defp create_test_repo do
    repo = "/tmp/mom-spend-test-#{System.unique_integer([:positive])}"
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    File.write!(
      Path.join(repo, "mix.exs"),
      """
      defmodule SpendAcceptance.MixProject do
        use Mix.Project

        def project do
          [app: :spend_acceptance, version: "0.1.0", elixir: "~> 1.15", deps: []]
        end

        def application, do: [extra_applications: [:logger]]
      end
      """
    )

    File.mkdir_p!(Path.join(repo, "test"))

    File.write!(
      Path.join(repo, "test/smoke_test.exs"),
      """
      ExUnit.start()

      defmodule SmokeTest do
        use ExUnit.Case

        test "ok" do
          assert true
        end
      end
      """
    )

    repo
  end

  defp normalize({:error, {:llm_failed, code, _out}}), do: {:error, {:llm_failed, code}}
  defp normalize({:error, {:git_failed, code, _out}}), do: {:error, {:git_failed, code}}
  defp normalize(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&normalize/1)
  defp normalize(term) when is_map(term), do: Map.new(term, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.MomCliSpendCapsScript.run()
