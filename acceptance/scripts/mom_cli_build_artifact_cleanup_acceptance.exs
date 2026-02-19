defmodule Mom.Acceptance.BuildArtifactCleanupScript do
  alias Mom.Config

  def run do
    root =
      Path.join(
        System.tmp_dir!(),
        "mom-build-artifact-cleanup-acceptance-#{System.unique_integer([:positive])}"
      )

    stale_runner = Path.join(root, "_build_runner_burst_stale")
    stale_worker = Path.join(root, "_build_acceptance_worker_stale_0")
    fresh_worker = Path.join(root, "_build_acceptance_worker_fresh_0")
    keep_other = Path.join(root, "_build_other_keep")

    File.rm_rf!(root)
    File.mkdir_p!(stale_runner)
    File.mkdir_p!(stale_worker)
    File.mkdir_p!(fresh_worker)
    File.mkdir_p!(keep_other)

    now = System.os_time(:second)
    set_directory_mtime!(stale_runner, now - 3_600)
    set_directory_mtime!(stale_worker, now - 3_600)
    set_directory_mtime!(fresh_worker, now)

    Application.put_env(:mom, :acceptance_build_artifact_retention_seconds, 300)
    Application.put_env(:mom, :acceptance_build_artifact_keep_latest, 1)

    result =
      try do
        File.cd!(root, fn ->
          {:ok, _config} =
            Config.from_opts(
              repo: "/tmp/repo",
              mode: :inproc,
              toolchain_node_version_override: "v24.6.0",
              toolchain_otp_version_override: "28.0.2"
            )
        end)

        %{
          pruned_runner_burst: not File.exists?(stale_runner),
          pruned_worker_scoped: not File.exists?(stale_worker),
          kept_recent_worker_scoped: File.dir?(fresh_worker),
          kept_non_matching_directory: File.dir?(keep_other)
        }
      after
        Application.delete_env(:mom, :acceptance_build_artifact_retention_seconds)
        Application.delete_env(:mom, :acceptance_build_artifact_keep_latest)
        File.rm_rf!(root)
      end

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
    :ok
  end

  defp set_directory_mtime!(path, unix_seconds) do
    datetime = :calendar.system_time_to_local_time(unix_seconds, :second)
    :ok = :file.change_time(String.to_charlist(path), datetime)
  end
end

Mom.Acceptance.BuildArtifactCleanupScript.run()
