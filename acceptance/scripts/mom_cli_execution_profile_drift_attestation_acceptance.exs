defmodule Mom.Acceptance.MomCliExecutionProfileDriftAttestationScript do
  def run do
    workdir = isolated_workdir_fixture()
    attached = attach_events()

    on_exit =
      fn ->
        Enum.each(attached, &:telemetry.detach/1)
      end

    try do
      passing =
        Mix.Tasks.Mom.parse_args([
          "/tmp/repo",
          "--llm",
          "codex",
          "--execution-profile",
          "production_hardened",
          "--workdir",
          workdir
        ])

      blocked =
        Mix.Tasks.Mom.parse_args([
          "/tmp/repo",
          "--llm",
          "codex",
          "--execution-profile",
          "staging_restricted",
          "--workdir",
          workdir,
          "--llm-cmd",
          "codex exec --sandbox workspace-write --cd /tmp"
        ])

      result = %{
        passing_profile: summarize_profile(passing),
        blocked_result: normalize(blocked),
        saw_attested_event: received?(:execution_profile_policy_attested),
        saw_drift_blocked_event: received?(:execution_profile_policy_drift_blocked)
      }

      IO.puts("RESULT_JSON:" <> Jason.encode!(result))
    after
      on_exit.()
    end
  end

  defp attach_events do
    events = [
      :execution_profile_policy_attested,
      :execution_profile_policy_drift_blocked
    ]

    Enum.map(events, fn event ->
      handler_id = "mom-acceptance-#{event}-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:mom, :audit, event],
          fn telemetry_event, _measurements, _metadata, pid ->
            event_name = telemetry_event |> List.last()
            send(pid, {:telemetry_event, event_name})
          end,
          self()
        )

      handler_id
    end)
  end

  defp received?(event_name) do
    receive do
      {:telemetry_event, ^event_name} -> true
    after
      50 -> false
    end
  end

  defp summarize_profile({:ok, config}), do: Atom.to_string(config.execution_profile)
  defp summarize_profile(other), do: normalize(other)

  defp isolated_workdir_fixture do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "mom-acceptance-drift-attestation-worktree-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)

    File.write!(
      Path.join(workdir, ".git"),
      "gitdir: /tmp/mom-acceptance-drift-attestation-gitdir\n"
    )

    workdir
  end

  defp normalize(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&normalize/1)
  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term) when is_map(term), do: Map.new(term, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize(term), do: term
end

Mom.Acceptance.MomCliExecutionProfileDriftAttestationScript.run()
