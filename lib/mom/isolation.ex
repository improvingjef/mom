defmodule Mom.Isolation do
  @moduledoc false

  alias Mom.{Config, Git}

  @spec prepare_workdir(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def prepare_workdir(%Config{repo: repo, workdir: workdir}) do
    cond do
      workdir ->
        {:ok, workdir}

      true ->
        tmp = Path.join(System.tmp_dir!(), "mom-#{System.unique_integer([:positive])}")
        with :ok <- File.mkdir_p(tmp),
             :ok <- Git.add_worktree(repo, tmp) do
          {:ok, tmp}
        end
    end
  end
end
