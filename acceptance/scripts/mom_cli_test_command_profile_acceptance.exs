defmodule Mom.Acceptance.MomCliTestCommandProfileScript do
  alias Mom.Git

  def run do
    {:ok, default_config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo"
      ])

    {:ok, custom_config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--test-command-profile",
        "mix_test_no_start"
      ])

    test_repo = create_test_repo()
    custom_test_run = normalize(Git.run_tests(test_repo, custom_config))

    invalid_result =
      normalize(
        Mix.Tasks.Mom.parse_args([
          "/tmp/repo",
          "--test-command-profile",
          "invalid_profile"
        ])
      )

    workdir = isolated_workdir_fixture()

    blocked_production_result =
      normalize(
        Mix.Tasks.Mom.parse_args([
          "/tmp/repo",
          "--llm",
          "codex",
          "--execution-profile",
          "production_hardened",
          "--workdir",
          workdir,
          "--test-command-profile",
          "mix_test_no_start"
        ])
      )

    result = %{
      default_test_command_profile: to_string(default_config.test_command_profile),
      custom_test_command_profile: to_string(custom_config.test_command_profile),
      custom_test_run: custom_test_run,
      invalid_result: invalid_result,
      blocked_production_result: blocked_production_result
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp create_test_repo do
    repo = "/tmp/mom-test-command-profile-#{System.unique_integer([:positive])}"
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    File.write!(
      Path.join(repo, "mix.exs"),
      """
      defmodule TestCommandProfileAcceptance.MixProject do
        use Mix.Project

        def project do
          [app: :test_command_profile_acceptance, version: "0.1.0", elixir: "~> 1.15", deps: []]
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
      defmodule TestCommandProfileSmokeTest do
        use ExUnit.Case

        test "ok" do
          assert true
        end
      end
      """
    )

    repo
  end

  defp isolated_workdir_fixture do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "mom-acceptance-test-profile-worktree-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, ".git"), "gitdir: /tmp/mom-acceptance-test-profile-gitdir\n")
    workdir
  end

  defp normalize({:error, {:git_failed, code, _out}}), do: {:error, {:git_failed, code}}
  defp normalize(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&normalize/1)
  defp normalize(term) when is_map(term), do: Map.new(term, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.MomCliTestCommandProfileScript.run()
