defmodule Mom.Acceptance.MomCliReadinessGateScript do
  def run do
    System.put_env("MOM_GITHUB_TOKEN", "token")
    System.put_env("MOM_GITHUB_CREDENTIAL_SCOPES", "contents,pull_requests,issues")
    workdir = isolated_workdir_fixture()

    blocked_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "acme/mom",
        "--actor-id",
        "mom-app[bot]",
        "--allowed-actor-ids",
        "mom-app[bot]"
      ])

    release_gate_blocked =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--llm",
        "codex",
        "--execution-profile",
        "production_hardened",
        "--workdir",
        workdir,
        "--github-repo",
        "acme/mom",
        "--actor-id",
        "mom-app[bot]",
        "--allowed-actor-ids",
        "mom-app[bot]",
        "--open-pr",
        "--readiness-gate-approved"
      ])

    canary_artifact_path =
      Path.join(
        System.tmp_dir!(),
        "mom-readiness-gate-canary-#{System.unique_integer([:positive])}.json"
      )

    try do
      payload = %{
        "run_id" => "acceptance-canary-42",
        "recorded_at_unix" => DateTime.utc_now() |> DateTime.to_unix(),
        "signal" => %{
          "success" => true,
          "pr_number" => 42,
          "pr_url" => "https://example/pull/42",
          "stop_point_classification" => %{"push" => "passed", "pr_create" => "passed"}
        }
      }

      signed_payload =
        Map.put(payload, "integrity", %{
          "content_sha256" => integrity_content_sha256(payload),
          "signer_key_id" => "unsigned",
          "signature" => nil
        })

      File.write!(canary_artifact_path, Jason.encode!(signed_payload) <> "\n")

      approved_result =
        Mix.Tasks.Mom.parse_args([
          "/tmp/repo",
          "--llm",
          "codex",
          "--execution-profile",
          "production_hardened",
          "--workdir",
          workdir,
          "--github-repo",
          "acme/mom",
          "--actor-id",
          "mom-app[bot]",
          "--allowed-actor-ids",
          "mom-app[bot]",
          "--open-pr",
          "--readiness-gate-approved",
          "--incident-to-pr-canary-artifact-path",
          canary_artifact_path,
          "--incident-to-pr-canary-max-age-seconds",
          "600"
        ])

      result = %{
        blocked_result: blocked_result,
        release_gate_blocked: release_gate_blocked,
        approved_gate: readiness_gate_approved(approved_result),
        approved_repo: github_repo(approved_result)
      }

      IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
    after
      File.rm_rf!(canary_artifact_path)
    end
  after
    System.delete_env("MOM_GITHUB_TOKEN")
    System.delete_env("MOM_GITHUB_CREDENTIAL_SCOPES")
  end

  defp readiness_gate_approved({:ok, config}), do: config.readiness_gate_approved
  defp readiness_gate_approved(_), do: false

  defp github_repo({:ok, config}), do: config.github_repo
  defp github_repo(_), do: nil

  defp isolated_workdir_fixture do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "mom-acceptance-readiness-worktree-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, ".git"), "gitdir: /tmp/mom-acceptance-readiness-gitdir\n")
    workdir
  end

  defp normalize(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&normalize/1)
  end

  defp normalize(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {k, normalize(v)} end)
  end

  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term

  defp integrity_content_sha256(content) do
    content
    |> normalize_integrity_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_integrity_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {normalize_integrity_key(key), normalize_integrity_term(nested)} end)
    |> Enum.sort_by(fn {key, _nested} -> key end)
  end

  defp normalize_integrity_term(value) when is_list(value), do: Enum.map(value, &normalize_integrity_term/1)

  defp normalize_integrity_term(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp normalize_integrity_term(value), do: value

  defp normalize_integrity_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_integrity_key(key), do: key
end

Mom.Acceptance.MomCliReadinessGateScript.run()
