defmodule Mom.Isolation do
  @moduledoc false

  alias Mom.{Config, Git}

  @tmp_worktree_prefix "mom-worktree-"
  @default_worktree_run_id "runtime"

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

  @spec tmp_workdir_basename(non_neg_integer(), map()) :: String.t()
  def tmp_workdir_basename(attempt, env \\ System.get_env())
      when is_integer(attempt) and attempt >= 0 and is_map(env) do
    run_id =
      env
      |> Map.get("MOM_WORKTREE_RUN_ID", @default_worktree_run_id)
      |> sanitize_segment()

    pid_segment =
      env
      |> Map.get("MOM_WORKTREE_PID", os_pid())
      |> sanitize_segment()

    "#{@tmp_worktree_prefix}#{run_id}-#{pid_segment}-#{attempt}"
  end

  @spec prune_ephemeral_tmp_worktrees(binary(), keyword()) ::
          {:ok,
           %{
             candidates: non_neg_integer(),
             kept: [binary()],
             removed: [binary()],
             failed: [{binary(), term()}]
           }}
          | {:error, term()}
  def prune_ephemeral_tmp_worktrees(root_path, opts \\ []) when is_binary(root_path) do
    retention_seconds = Keyword.get(opts, :retention_seconds, 86_400)
    keep_latest = Keyword.get(opts, :keep_latest, 16)
    now_seconds = Keyword.get(opts, :now_seconds, System.os_time(:second))

    with {:ok, entries} <- File.ls(root_path) do
      candidates =
        entries
        |> Enum.flat_map(&tmp_worktree_candidate(root_path, &1))
        |> Enum.sort_by(& &1.modified_seconds, :desc)

      {kept, removed, failed} =
        candidates
        |> Enum.with_index()
        |> Enum.reduce({[], [], []}, fn {entry, index}, {kept, removed, failed} ->
          keep_by_rank? = index < keep_latest
          within_retention? = now_seconds - entry.modified_seconds <= retention_seconds

          cond do
            keep_by_rank? or within_retention? ->
              {[entry.name | kept], removed, failed}

            true ->
              case File.rm_rf(entry.path) do
                {:ok, _deleted_paths} ->
                  {kept, [entry.name | removed], failed}

                {:error, reason, _path} ->
                  {kept, removed, [{entry.name, reason} | failed]}
              end
          end
        end)

      {:ok,
       %{
         candidates: length(candidates),
         kept: Enum.sort(kept),
         removed: Enum.sort(removed),
         failed: Enum.sort_by(failed, &elem(&1, 0))
       }}
    end
  end

  defp unique_tmp_workdir(attempts \\ 10)
  defp unique_tmp_workdir(0), do: {:error, :workdir_allocation_failed}

  defp unique_tmp_workdir(attempts) do
    attempt_index = 10 - attempts
    candidate = Path.join(System.tmp_dir!(), tmp_workdir_basename(attempt_index))

    if File.exists?(candidate) do
      unique_tmp_workdir(attempts - 1)
    else
      {:ok, candidate}
    end
  end

  defp tmp_worktree_candidate(root_path, entry_name) do
    path = Path.join(root_path, entry_name)

    with true <- String.starts_with?(entry_name, @tmp_worktree_prefix),
         {:ok, %File.Stat{type: :directory}} <- File.stat(path),
         {:ok, %File.Stat{mtime: modified_seconds}} <- File.stat(path, time: :posix) do
      [%{name: entry_name, path: path, modified_seconds: modified_seconds}]
    else
      _ -> []
    end
  end

  defp sanitize_segment(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    |> case do
      "" -> "default"
      sanitized -> sanitized
    end
  end

  defp os_pid do
    :os.getpid()
    |> List.to_string()
  end
end
