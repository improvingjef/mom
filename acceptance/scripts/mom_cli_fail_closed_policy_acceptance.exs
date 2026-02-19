defmodule Mom.Acceptance.MomCliFailClosedPolicyScript do
  alias Mom.LLM

  def run do
    workdir = isolated_workdir_fixture()

    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex",
        "--execution-profile",
        "staging_restricted",
        "--workdir",
        workdir
      ])

    drifted = %{config | llm_cmd: "codex --yolo exec --sandbox workspace-write"}

    blocked =
      LLM.generate_text(
        %{report: %{status: :ok}, issues: [], instructions: "summarize"},
        drifted
      )

    result = %{
      execution_profile: Atom.to_string(config.execution_profile),
      blocked_result: normalize(blocked)
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp isolated_workdir_fixture do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "mom-acceptance-fail-closed-worktree-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, ".git"), "gitdir: /tmp/mom-acceptance-fail-closed-gitdir\n")
    workdir
  end

  defp normalize({:ok, value}), do: ["ok", normalize(value)]
  defp normalize({:error, value}), do: ["error", normalize(value)]
  defp normalize(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&normalize/1)
  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.MomCliFailClosedPolicyScript.run()
