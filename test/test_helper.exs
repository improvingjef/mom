ExUnit.start()

defmodule Mom.TestHelper do
  def reset_rate_limiter do
    case :ets.whereis(:mom_rate_limiter) do
      :undefined -> :ok
      _ -> :ets.delete(:mom_rate_limiter)
    end
  end

  def create_repo do
    base = Path.join(System.tmp_dir!(), "mom-test-repo-#{System.unique_integer([:positive])}")
    File.rm_rf!(base)
    :ok = File.mkdir_p(base)

    git(base, ["init"])
    git(base, ["config", "user.email", "mom@example.com"])
    git(base, ["config", "user.name", "mom"])

    File.write!(Path.join(base, "README.md"), "mom test\n")
    git(base, ["add", "."])
    git(base, ["commit", "-m", "init"])

    base
  end

  def git(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir)
    :ok
  end
end
