defmodule Mom.Acceptance.MomCliBranchPolicyScript do
  def run do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--branch-name-prefix",
        "mom/incidents"
      ])

    repo = create_repo()
    File.write!(Path.join(repo, "lib_acceptance.ex"), "defmodule AcceptanceFile do end\n")

    {:ok, branch} = Mom.Git.commit_changes(repo, "mom: branch policy acceptance", config.branch_name_prefix)

    invalid_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--branch-name-prefix",
        "bad prefix"
      ])

    result = %{
      branch_name_prefix: config.branch_name_prefix,
      generated_branch: branch,
      prefix_matches: String.starts_with?(branch, "mom/incidents-"),
      invalid_result: invalid_result
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  end

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
    Map.new(term, fn {k, v} -> {k, normalize(v)} end)
  end

  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.MomCliBranchPolicyScript.run()
