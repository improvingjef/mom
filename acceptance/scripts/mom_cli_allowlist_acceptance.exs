defmodule Mom.Acceptance.MomCliAllowlistScript do
  def run do
    handler_id = "mom-acceptance-allowlist-alert-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:mom, :alert, :unusual_activity],
        fn event, _measurements, metadata, pid ->
          send(pid, {:alert_event, event, metadata})
        end,
        self()
      )

    {:ok, allowed_config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "acme/mom",
        "--allowed-github-repos",
        "acme/mom,acme/other"
      ])

    blocked_result =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--github-repo",
        "evil/repo",
        "--allowed-github-repos",
        "acme/mom,acme/other"
      ])

    alerts = drain_alerts([])
    :telemetry.detach(handler_id)

    result = %{
      allowed_repo: allowed_config.github_repo,
      allowed_list: allowed_config.allowed_github_repos,
      blocked_result: blocked_result,
      saw_disallowed_repo_alert: saw_alert?(alerts, :disallowed_repo_target),
      disallowed_alert_repo: alert_value(alerts, :disallowed_repo_target, :repo)
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  end

  defp drain_alerts(acc) do
    receive do
      {:alert_event, event, metadata} ->
        drain_alerts([{event, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp saw_alert?(alerts, alert_type) do
    Enum.any?(alerts, fn
      {[:mom, :alert, :unusual_activity], %{alert_type: ^alert_type}} -> true
      _ -> false
    end)
  end

  defp alert_value(alerts, alert_type, key) do
    case Enum.find(alerts, fn
           {[:mom, :alert, :unusual_activity], %{alert_type: ^alert_type}} -> true
           _ -> false
         end) do
      {_, metadata} -> Map.get(metadata, key)
      nil -> nil
    end
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
end

Mom.Acceptance.MomCliAllowlistScript.run()
