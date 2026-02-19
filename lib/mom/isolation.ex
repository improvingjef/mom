defmodule Mom.Isolation do
  @moduledoc false

  alias Mom.{Config, Git}

  @spec prepare_workdir(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def prepare_workdir(%Config{repo: repo, workdir: workdir}) do
    cond do
      is_binary(workdir) ->
        if isolated_worktree?(workdir) do
          {:ok, workdir}
        else
          {:error, :workdir_must_be_isolated_worktree}
        end

      true ->
        tmp = Path.join(System.tmp_dir!(), "mom-#{System.unique_integer([:positive])}")

        with :ok <- File.mkdir_p(tmp),
             :ok <- Git.add_worktree(repo, tmp) do
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
end
