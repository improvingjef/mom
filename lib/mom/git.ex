defmodule Mom.Git do
  @moduledoc false

  alias Mom.Audit

  @spec add_worktree(String.t(), String.t()) :: :ok | {:error, term()}
  def add_worktree(repo, workdir) do
    cmd(repo, ["worktree", "add", workdir]) |> ok_or_error()
  end

  @spec apply_patch(String.t(), String.t()) :: :ok | {:error, term()}
  def apply_patch(workdir, patch) do
    tmp = Path.join(System.tmp_dir!(), "mom-patch-#{System.unique_integer([:positive])}.diff")
    File.write!(tmp, patch)

    case System.cmd("git", ["apply", tmp], cd: workdir) do
      {_, 0} ->
        File.rm(tmp)
        :ok

      {out, code} ->
        File.rm(tmp)
        {:error, {:git_apply_failed, code, out}}
    end
  end

  @spec run_tests(String.t()) :: :ok | {:error, term()}
  def run_tests(workdir) do
    cmd(workdir, ["mix", "test"]) |> ok_or_error()
  end

  @spec touches_tests?(String.t()) :: boolean()
  def touches_tests?(workdir) do
    case cmd(workdir, ["status", "--porcelain"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          case String.split(line, " ", parts: 2, trim: true) do
            [_status, path] -> String.starts_with?(path, "test/")
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  @spec commit_changes(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def commit_changes(workdir, message, branch_name_prefix \\ "mom", audit_opts \\ []) do
    branch = "#{branch_name_prefix}-#{System.unique_integer([:positive])}"

    with :ok <- cmd(workdir, ["checkout", "-b", branch]) |> ok_or_error(),
         :ok <- cmd(workdir, ["add", "."]) |> ok_or_error(),
         :ok <- cmd(workdir, ["commit", "-m", message]) |> ok_or_error() do
      emit_branch_audit(branch, audit_opts)
      {:ok, branch}
    end
  end

  @spec push_branch(String.t(), String.t()) :: :ok | {:error, term()}
  def push_branch(workdir, branch) do
    cmd(workdir, ["push", "origin", branch]) |> ok_or_error()
  end

  defp cmd(workdir, args) do
    System.cmd("git", args, cd: workdir)
  end

  defp ok_or_error({_, 0}), do: :ok
  defp ok_or_error({out, code}), do: {:error, {:git_failed, code, out}}

  defp emit_branch_audit(branch, audit_opts) do
    metadata = %{
      repo: Keyword.get(audit_opts, :repo),
      actor_id: Keyword.get(audit_opts, :actor_id, "mom"),
      branch: branch
    }

    Audit.emit(:git_branch_created, metadata)
  end
end
