defmodule Mom.Acceptance.IncidentToPrFailureClassificationScript do
  alias Mom.IncidentToPr

  def run do
    result = %{
      detect: classify(:detect),
      patch_apply: classify(:patch_apply),
      tests: classify(:tests),
      push: classify(:push),
      pr_create: classify(:pr_create)
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end

  defp classify(stop_point) do
    {:error, signal} = IncidentToPr.evaluate(events_for(stop_point))
    normalize(signal)
  end

  defp events_for(:detect) do
    [
      {[:mom, :audit, :github_issue_failed], %{repo: "acme/mom", actor_id: "bot"}},
      {[:mom, :audit, :git_patch_applied], %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]
  end

  defp events_for(:patch_apply) do
    [
      {[:mom, :audit, :github_issue_created], %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_failed], %{repo: "acme/mom", actor_id: "bot"}},
      {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]
  end

  defp events_for(:tests) do
    [
      {[:mom, :audit, :github_issue_created], %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_applied], %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "error"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]
  end

  defp events_for(:push) do
    [
      {[:mom, :audit, :github_issue_created], %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_applied], %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
      {[:mom, :audit, :git_branch_push_failed], %{repo: "acme/mom", actor_id: "bot"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]
  end

  defp events_for(:pr_create) do
    [
      {[:mom, :audit, :github_issue_created], %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_applied], %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_failed], %{repo: "acme/mom", actor_id: "bot"}}
    ]
  end

  defp normalize(term) when is_map(term) do
    Map.new(term, fn {key, value} -> {to_string(key), normalize(value)} end)
  end

  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)
  defp normalize(term), do: term
end

Mom.Acceptance.IncidentToPrFailureClassificationScript.run()
