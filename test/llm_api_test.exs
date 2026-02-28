defmodule Mom.LLMApiTest do
  use ExUnit.Case

  alias Mom.{Config, LLM}

  test "api provider requires key" do
    {:ok, config} = Config.from_opts(repo: "/tmp/repo", llm_provider: :api_openai)
    context = %{report: %{}, issues: [], instructions: "say ok"}
    assert {:error, _} = LLM.generate_text(context, config)
  end

  test "api provider blocks egress to non-allowlisted host" do
    {:ok, base_config} = Config.from_opts(repo: "/tmp/repo")

    config = %{
      base_config
      | llm: %{
          base_config.llm
          | provider: :api_openai,
            api_key: "key",
            api_url: "https://proxy.invalid/v1/chat/completions"
        },
        governance: %{
          base_config.governance
          | allowed_egress_hosts: ["api.github.com", "api.openai.com"]
        }
    }

    context = %{report: %{}, issues: [], instructions: "say ok"}

    assert {:error, {:egress_blocked, "proxy.invalid"}} =
             LLM.generate_text(context, config)
  end
end
