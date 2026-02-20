defmodule Mom.GitTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Mom.{Git, Isolation, Config}

  setup do
    Mom.TestHelper.reset_spend_limiter()
    :ok
  end

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

  test "apply_patch emits audit event with actor, repo, and workdir" do
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

    telemetry_handler = "git-patch-applied-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_handler,
      [[:mom, :audit, :git_patch_applied]],
      fn event, _measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    log =
      capture_log(fn ->
        assert :ok =
                 Git.apply_patch(repo, patch,
                   actor_id: "machine-user",
                   repo: "acme/mom"
                 )
      end)

    assert_receive {:telemetry_event, [:mom, :audit, :git_patch_applied], metadata}
    assert metadata.actor_id == "machine-user"
    assert metadata.repo == "acme/mom"
    assert metadata.workdir == repo
    assert log =~ "\"event\":\"git_patch_applied\""
    assert log =~ "\"actor_id\":\"machine-user\""
  end

  test "prepare_workdir creates a git worktree" do
    repo = Mom.TestHelper.create_repo()
    {:ok, config} = Config.from_opts(repo: repo)

    {:ok, workdir} = Isolation.prepare_workdir(config)
    assert File.exists?(Path.join(workdir, ".git"))
  end

  test "prepare_workdir uses deterministic collision-safe temp worktree naming" do
    repo = Mom.TestHelper.create_repo()
    run_id = "git test/run ##{System.unique_integer([:positive])}"
    env = %{"MOM_WORKTREE_RUN_ID" => run_id}
    collision = Path.join(System.tmp_dir!(), Isolation.tmp_workdir_basename(0, env))

    on_exit(fn ->
      System.delete_env("MOM_WORKTREE_RUN_ID")
      File.rm_rf!(collision)

      _ =
        System.cmd("git", ["worktree", "prune"], cd: repo, stderr_to_stdout: true)
    end)

    System.put_env("MOM_WORKTREE_RUN_ID", run_id)
    File.rm_rf!(collision)
    File.mkdir_p!(collision)

    {:ok, config} = Config.from_opts(repo: repo)
    {:ok, workdir} = Isolation.prepare_workdir(config)

    expected = Isolation.tmp_workdir_basename(1, env)
    assert Path.basename(workdir) == expected
    assert File.exists?(Path.join(workdir, ".git"))
    {_, 0} = System.cmd("git", ["worktree", "remove", "--force", workdir], cd: repo)
  end

  test "prepare_workdir emits worktree audit event with actor and repo" do
    repo = Mom.TestHelper.create_repo()

    {:ok, config} =
      Config.from_opts(
        repo: repo,
        github_repo: "acme/mom",
        actor_id: "machine-bot",
        allowed_actor_ids: ["machine-bot"]
      )

    telemetry_handler = "git-worktree-created-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_handler,
      [[:mom, :audit, :git_worktree_created]],
      fn event, _measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    log =
      capture_log(fn ->
        assert {:ok, workdir} = Isolation.prepare_workdir(config)
        assert File.exists?(Path.join(workdir, ".git"))
      end)

    assert_receive {:telemetry_event, [:mom, :audit, :git_worktree_created], metadata}
    assert metadata.actor_id == "machine-bot"
    assert metadata.repo == "acme/mom"
    assert is_binary(metadata.workdir)
    assert log =~ "\"event\":\"git_worktree_created\""
    assert log =~ "\"actor_id\":\"machine-bot\""
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

  test "push_branch emits audit event with repo, branch, and actor id" do
    base = Path.join(System.tmp_dir!(), "mom-git-push-#{System.unique_integer([:positive])}")
    remote = Path.join(base, "remote.git")
    local = Path.join(base, "local")

    File.rm_rf!(base)
    File.mkdir_p!(base)
    {_, 0} = System.cmd("git", ["init", "--bare", remote])
    File.mkdir_p!(local)
    {_, 0} = System.cmd("git", ["init"], cd: local)
    {_, 0} = System.cmd("git", ["config", "user.email", "mom@example.com"], cd: local)
    {_, 0} = System.cmd("git", ["config", "user.name", "mom"], cd: local)

    File.write!(Path.join(local, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: local)
    {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: local)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", remote], cd: local)
    {_, 0} = System.cmd("git", ["checkout", "-b", "mom/push-audit"], cd: local)

    telemetry_handler = "git-branch-pushed-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_handler,
      [[:mom, :audit, :git_branch_pushed]],
      fn event, _measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    log =
      capture_log(fn ->
        assert :ok =
                 Git.push_branch(local, "mom/push-audit",
                   actor_id: "machine-user",
                   repo: "acme/mom"
                 )
      end)

    assert_receive {:telemetry_event, [:mom, :audit, :git_branch_pushed], metadata}
    assert metadata.actor_id == "machine-user"
    assert metadata.repo == "acme/mom"
    assert metadata.branch == "mom/push-audit"
    assert log =~ "\"event\":\"git_branch_pushed\""
    assert log =~ "\"actor_id\":\"machine-user\""
  end

  test "enforces per-repo test execution spend cap" do
    repo = Mom.TestHelper.create_repo()

    {:ok, config} =
      Config.from_opts(
        repo: repo,
        test_spend_cap_cents_per_hour: 1,
        test_run_cost_cents: 1
      )

    assert {:error, _} = Git.run_tests(repo, config)
    assert {:error, :test_spend_cap_exceeded} = Git.run_tests(repo, config)
  end

  test "run_tests executes configured test command profile" do
    repo = create_mix_test_repo()

    {:ok, config} =
      Config.from_opts(
        repo: repo,
        test_command_profile: :mix_test_no_start
      )

    assert :ok == Git.run_tests(repo, config)
  end

  test "run_tests emits audit event with profile and command details" do
    repo = create_mix_test_repo()

    {:ok, config} =
      Config.from_opts(
        repo: repo,
        actor_id: "machine-user",
        github_repo: "acme/mom",
        allowed_actor_ids: ["machine-user"],
        test_command_profile: :mix_test_no_start
      )

    telemetry_handler = "git-tests-run-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_handler,
      [[:mom, :audit, :git_tests_run]],
      fn event, _measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    log =
      capture_log(fn ->
        assert :ok == Git.run_tests(repo, config)
      end)

    assert_receive {:telemetry_event, [:mom, :audit, :git_tests_run], metadata}
    assert metadata.actor_id == "machine-user"
    assert metadata.repo == "acme/mom"
    assert metadata.workdir == repo
    assert metadata.test_command_profile == "mix_test_no_start"
    assert metadata.exit_code == 0
    assert metadata.status == "ok"
    assert metadata.command == "mix test --no-start"
    assert log =~ "\"event\":\"git_tests_run\""
    assert log =~ "\"test_command_profile\":\"mix_test_no_start\""
  end

  defp create_mix_test_repo do
    repo = Path.join(System.tmp_dir!(), "mom-git-tests-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    File.write!(
      Path.join(repo, "mix.exs"),
      """
      defmodule GitRunTestsAcceptance.MixProject do
        use Mix.Project

        def project do
          [app: :git_run_tests_acceptance, version: "0.1.0", elixir: "~> 1.15", deps: []]
        end

        def application, do: [extra_applications: [:logger]]
      end
      """
    )

    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(repo, "test/smoke_test.exs"),
      """
      defmodule GitRunTestsSmokeTest do
        use ExUnit.Case

        test "ok" do
          assert true
        end
      end
      """
    )

    repo
  end
end
