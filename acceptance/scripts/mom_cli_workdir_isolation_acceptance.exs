defmodule Mom.Acceptance.MomCliWorkdirIsolationScript do
  def run do
    repo = create_repo()

    invalid =
      Mix.Tasks.Mom.parse_args([
        repo,
        "--workdir",
        repo
      ])

    workdir = Path.join(System.tmp_dir!(), "mom-acceptance-worktree-#{System.unique_integer([:positive])}")
    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    :ok = git(repo, ["worktree", "add", workdir])

    valid =
      Mix.Tasks.Mom.parse_args([
        repo,
        "--workdir",
        workdir
      ])

    result = %{
      invalid: invalid,
      valid_result: match_result(valid),
      valid_workdir: valid_workdir(valid) == workdir
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  end

  defp match_result({:ok, _config}), do: :ok
  defp match_result({:error, reason}), do: {:error, reason}

  defp valid_workdir({:ok, config}), do: config.workdir
  defp valid_workdir(_), do: nil

  defp create_repo do
    base = Path.join(System.tmp_dir!(), "mom-acceptance-repo-#{System.unique_integer([:positive])}")
    File.rm_rf!(base)
    File.mkdir_p!(base)

    git(base, ["init"])
    git(base, ["config", "user.email", "mom@example.com"])
    git(base, ["config", "user.name", "mom"])

    File.write!(Path.join(base, "README.md"), "mom acceptance\n")
    git(base, ["add", "."])
    git(base, ["commit", "-m", "init"])

    base
  end

  defp git(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir)
    :ok
  end

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

Mom.Acceptance.MomCliWorkdirIsolationScript.run()
