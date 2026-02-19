defmodule Mom.Acceptance.MomCLIStagingProfileScript do
  def run do
    workdir = isolated_workdir_fixture()

    {:ok, valid} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex",
        "--execution-profile",
        "staging_restricted",
        "--workdir",
        workdir
      ])

    missing_sandbox =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex",
        "--execution-profile",
        "staging_restricted",
        "--workdir",
        workdir,
        "--llm-cmd",
        "codex exec"
      ])

    yolo_disallowed =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex",
        "--execution-profile",
        "staging_restricted",
        "--workdir",
        workdir,
        "--llm-cmd",
        "codex --yolo exec --sandbox workspace-write"
      ])

    result = %{
      execution_profile: Atom.to_string(valid.execution_profile),
      llm_cmd: valid.llm_cmd,
      sandbox_mode: Atom.to_string(valid.sandbox_mode),
      command_allowlist: valid.command_allowlist,
      write_boundaries: valid.write_boundaries,
      missing_sandbox: normalize(missing_sandbox),
      yolo_disallowed: normalize(yolo_disallowed)
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp isolated_workdir_fixture do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "mom-acceptance-staging-worktree-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, ".git"), "gitdir: /tmp/mom-acceptance-staging-gitdir\n")
    workdir
  end

  defp normalize({:ok, config}), do: ["ok", normalize(config)]
  defp normalize({:error, reason}), do: ["error", reason]

  defp normalize(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&normalize/1)
  end

  defp normalize(term) when is_map(term) do
    normalized_map =
      if Map.has_key?(term, :__struct__) do
        Map.from_struct(term)
      else
        term
      end

    Map.new(normalized_map, fn {k, v} -> {k, normalize(v)} end)
  end

  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.MomCLIStagingProfileScript.run()
