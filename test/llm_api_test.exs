defmodule Mom.LLMApiTest do
  use ExUnit.Case

  alias Mom.{Config, LLM}

  test "api provider requires key" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo", llm_provider: :api_openai)
    context = %{report: %{}, issues: [], instructions: "say ok"}
    assert {:error, _} = LLM.generate_text(context, config)
  end
end
