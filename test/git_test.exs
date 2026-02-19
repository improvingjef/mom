defmodule Mom.GitTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Mom.{Git, Isolation, Config}

  test "touches_tests? detects test changes" do
    repo = Mom.TestHelper.create_repo()
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "test/sample_test.exs"), "test\n")

    assert Git.touches_tests?(repo) == true
  end

  test "touches_tests? ignores non-test changes" do
    repo = Mom.TestHelper.create_repo()
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/sample.ex"), "defmodule A do end\n")

    assert Git.touches_tests?(repo) == false
  end

  test "apply_patch applies a unified diff" do
    repo = Mom.TestHelper.create_repo()
    file = Path.join(repo, "lib.txt")
    File.write!(file, "a\n")
    Mom.TestHelper.git(repo, ["add", "."])
    Mom.TestHelper.git(repo, ["commit", "-m", "add file"])

    patch = """
    diff --git a/lib.txt b/lib.txt
    index 2e65efe..8c7e5a6 100644
    --- a/lib.txt
    +++ b/lib.txt
    @@ -1 +1,2 @@
     a
    +b
    """

    assert :ok == Git.apply_patch(repo, patch)
    assert File.read!(file) == "a\nb\n"
  end

  test "prepare_workdir creates a git worktree" do
    repo = Mom.TestHelper.create_repo()
    {:ok, config} = Config.from_opts(repo: repo)

    {:ok, workdir} = Isolation.prepare_workdir(config)
    assert File.exists?(Path.join(workdir, ".git"))
  end

  test "prepare_workdir rejects explicit non-worktree path" do
    repo = Mom.TestHelper.create_repo()
    config = %Config{repo: repo, workdir: repo}

    assert {:error, :workdir_must_be_isolated_worktree} = Isolation.prepare_workdir(config)
  end

  test "commit_changes uses configured branch naming prefix" do
    repo = Mom.TestHelper.create_repo()
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/new_file.ex"), "defmodule NewFile do end\n")

    assert {:ok, branch} = Git.commit_changes(repo, "mom: branch prefix", "mom/incidents")
    assert String.starts_with?(branch, "mom/incidents-")
  end

  test "commit_changes emits audit event with repo, branch, and actor id" do
    repo = Mom.TestHelper.create_repo()
    File.write!(Path.join(repo, "AUDIT.md"), "audit\n")

    telemetry_handler = "git-branch-created-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_handler,
      [[:mom, :audit, :git_branch_created]],
      fn event, _measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    log =
      capture_log(fn ->
        assert {:ok, branch} =
                 Git.commit_changes(
                   repo,
                   "mom: branch audit",
                   "mom/audit",
                   actor_id: "machine-user",
                   repo: "acme/mom"
                 )

        assert String.starts_with?(branch, "mom/audit-")
      end)

    assert_receive {:telemetry_event, [:mom, :audit, :git_branch_created], metadata}
    assert metadata.actor_id == "machine-user"
    assert metadata.repo == "acme/mom"
    assert String.starts_with?(metadata.branch, "mom/audit-")
    assert log =~ "\"event\":\"git_branch_created\""
    assert log =~ "\"actor_id\":\"machine-user\""
  end
end
