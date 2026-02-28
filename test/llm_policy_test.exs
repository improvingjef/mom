defmodule Mom.LLMPolicyTest do
  use ExUnit.Case

  alias Mom.{Config, LLM}

  setup do
    Mom.TestHelper.reset_rate_limiter()
    :ok
  end

  test "generate_text fails closed when execution profile policy is violated at runtime" do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "mom-llm-policy-worktree-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, ".git"), "gitdir: /tmp/mom-llm-policy-gitdir\n")

    {:ok, config} =
      Config.from_opts(
        repo: "/tmp/repo",
        llm_provider: :codex,
        execution_profile: :staging_restricted,
        workdir: workdir,
        llm_cmd: "codex exec --sandbox workspace-write",
        llm_rate_limit_per_hour: 10
      )

    drifted = %{
      config
      | llm: %{config.llm | cmd: "codex --yolo exec --sandbox workspace-write"}
    }
    context = %{report: %{status: :ok}, issues: [], instructions: "summarize"}

    assert {:error, {:policy_violation, "staging_restricted forbids --yolo execution"}} =
             LLM.generate_text(context, drifted)
  end
end
