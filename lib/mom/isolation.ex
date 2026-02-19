defmodule Mom.Isolation do
  @moduledoc false

  alias Mom.{Config, Git}

  @spec prepare_workdir(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def prepare_workdir(%Config{repo: repo, workdir: workdir} = config) do
    cond do
      is_binary(workdir) ->
        if isolated_worktree?(workdir) do
          {:ok, workdir}
        else
          {:error, :workdir_must_be_isolated_worktree}
        end

      true ->
        with {:ok, tmp} <- unique_tmp_workdir(),
             :ok <-
               Git.add_worktree(repo, tmp, actor_id: config.actor_id, repo: target_repo(config)) do
          {:ok, tmp}
        end
    end
  end

  @spec isolated_worktree?(String.t()) :: boolean()
  def isolated_worktree?(path) when is_binary(path) do
    git_file = Path.join(path, ".git")

    with {:ok, %File.Stat{type: :regular}} <- File.stat(git_file),
         {:ok, contents} <- File.read(git_file) do
      String.starts_with?(String.trim_leading(contents), "gitdir:")
    else
      _ -> false
    end
  end

  defp target_repo(%Config{github_repo: nil, repo: repo}), do: repo
  defp target_repo(%Config{github_repo: github_repo}), do: github_repo

  defp unique_tmp_workdir(attempts \\ 10)
  defp unique_tmp_workdir(0), do: {:error, :workdir_allocation_failed}

  defp unique_tmp_workdir(attempts) do
    candidate = Path.join(System.tmp_dir!(), "mom-#{System.unique_integer([:positive])}")

    if File.exists?(candidate) do
      unique_tmp_workdir(attempts - 1)
    else
      {:ok, candidate}
    end
  end
end
