defmodule Mom.GitTest do
  use ExUnit.Case

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
end
