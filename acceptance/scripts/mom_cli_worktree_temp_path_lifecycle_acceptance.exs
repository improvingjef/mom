defmodule Mom.Acceptance.MomCliWorktreeTempPathLifecycleScript do
  alias Mom.{Config, Isolation}

  def run do
    run_id = "acceptance/worktree-#{System.unique_integer([:positive])}"
    cleanup_env = %{"MOM_WORKTREE_RUN_ID" => run_id, "MOM_WORKTREE_PID" => "cleanup"}
    stale_dir = Path.join(System.tmp_dir!(), Isolation.tmp_workdir_basename(1, cleanup_env))
    fresh_dir = Path.join(System.tmp_dir!(), Isolation.tmp_workdir_basename(2, cleanup_env))

    repo = create_repo()
    expected_worktree_basename = Isolation.tmp_workdir_basename(1, %{"MOM_WORKTREE_RUN_ID" => run_id})
    collision_dir = Path.join(System.tmp_dir!(), Isolation.tmp_workdir_basename(0, %{"MOM_WORKTREE_RUN_ID" => run_id}))

    File.rm_rf!(stale_dir)
    File.rm_rf!(fresh_dir)
    File.rm_rf!(collision_dir)
    File.mkdir_p!(stale_dir)
    File.mkdir_p!(fresh_dir)
    File.mkdir_p!(collision_dir)

    now = System.os_time(:second)
    set_directory_mtime!(stale_dir, now - 3_600)
    set_directory_mtime!(fresh_dir, now)

    Application.put_env(:mom, :temp_worktree_retention_seconds, 300)
    Application.put_env(:mom, :temp_worktree_keep_latest, 1)
    System.put_env("MOM_WORKTREE_RUN_ID", run_id)

    result =
      try do
        {:ok, config} =
          Config.from_opts(
            repo: repo,
            mode: :inproc,
            toolchain_node_version_override: "v24.6.0",
            toolchain_otp_version_override: "28.0.2"
          )

        {:ok, workdir} = Isolation.prepare_workdir(config)
        {_, 0} = System.cmd("git", ["worktree", "remove", "--force", workdir], cd: repo)

        %{
          pruned_stale_worktree: not File.exists?(stale_dir),
          kept_recent_worktree: File.dir?(fresh_dir),
          collision_avoided: Path.basename(workdir) == expected_worktree_basename,
          worktree_path_deterministic: String.starts_with?(Path.basename(workdir), "mom-worktree-")
        }
      after
        Application.delete_env(:mom, :temp_worktree_retention_seconds)
        Application.delete_env(:mom, :temp_worktree_keep_latest)
        System.delete_env("MOM_WORKTREE_RUN_ID")
        File.rm_rf!(stale_dir)
        File.rm_rf!(fresh_dir)
        File.rm_rf!(collision_dir)
        File.rm_rf!(repo)
      end

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp create_repo do
    base = Path.join(System.tmp_dir!(), "mom-acceptance-worktree-lifecycle-#{System.unique_integer([:positive])}")
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

  defp set_directory_mtime!(path, unix_seconds) do
    datetime = :calendar.system_time_to_local_time(unix_seconds, :second)
    :ok = :file.change_time(String.to_charlist(path), datetime)
  end
end

Mom.Acceptance.MomCliWorktreeTempPathLifecycleScript.run()
