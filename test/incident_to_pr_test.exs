defmodule Mom.IncidentToPrTest do
  use ExUnit.Case, async: true

  alias Mom.IncidentToPr

  test "reports success when incident-to-PR audit steps are complete and ordered" do
    events = [
      {[:mom, :audit, :github_issue_created],
       %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_applied],
       %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]

    assert {:ok, signal} = IncidentToPr.evaluate(events)
    assert signal.success
    assert signal.pr_number == 11
    assert signal.branch == "mom/1"
    assert signal.missing_steps == []
    assert signal.out_of_order_steps == []
    assert signal.stop_point_classification == %{
             detect: :passed,
             patch_apply: :passed,
             tests: :passed,
             push: :passed,
             pr_create: :passed
           }
    assert signal.failure_stop_point == nil
  end

  test "reports failure when required audit events are missing" do
    events = [
      {[:mom, :audit, :github_issue_created],
       %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_applied],
       %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]

    assert {:error, signal} = IncidentToPr.evaluate(events)
    assert signal.success == false
    assert signal.missing_steps == [:tests_passed]
    assert signal.stop_point_classification.tests == :missing
    assert signal.failure_stop_point == :tests
  end

  test "reports failure when tests fail even if pr is created" do
    events = [
      {[:mom, :audit, :github_issue_created],
       %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
      {[:mom, :audit, :git_patch_applied],
       %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
      {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "error"}},
      {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
      {[:mom, :audit, :github_pr_created],
       %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
    ]

    assert {:error, signal} = IncidentToPr.evaluate(events)
    assert signal.success == false
    assert signal.tests_status_ok == false
    assert signal.stop_point_classification.tests == :failed
    assert signal.failure_stop_point == :tests
  end

  test "classifies each stop point failure from audit stream" do
    scenarios = [
      {:detect,
       [
         {[:mom, :audit, :github_issue_failed], %{repo: "acme/mom", actor_id: "bot"}},
         {[:mom, :audit, :git_patch_applied],
          %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
         {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
         {[:mom, :audit, :github_pr_created],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
       ]},
      {:patch_apply,
       [
         {[:mom, :audit, :github_issue_created],
          %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
         {[:mom, :audit, :git_patch_failed], %{repo: "acme/mom", actor_id: "bot"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
         {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
         {[:mom, :audit, :github_pr_created],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
       ]},
      {:tests,
       [
         {[:mom, :audit, :github_issue_created],
          %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
         {[:mom, :audit, :git_patch_applied],
          %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "error"}},
         {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
         {[:mom, :audit, :github_pr_created],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
       ]},
      {:push,
       [
         {[:mom, :audit, :github_issue_created],
          %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
         {[:mom, :audit, :git_patch_applied],
          %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
         {[:mom, :audit, :git_branch_push_failed], %{repo: "acme/mom", actor_id: "bot"}},
         {[:mom, :audit, :github_pr_created],
          %{repo: "acme/mom", actor_id: "bot", branch: "mom/1", pr_number: 11}}
       ]},
      {:pr_create,
       [
         {[:mom, :audit, :github_issue_created],
          %{repo: "acme/mom", actor_id: "bot", issue_number: 7}},
         {[:mom, :audit, :git_patch_applied],
          %{repo: "acme/mom", actor_id: "bot", workdir: "/tmp/w"}},
         {[:mom, :audit, :git_tests_run], %{repo: "acme/mom", actor_id: "bot", status: "ok"}},
         {[:mom, :audit, :git_branch_pushed], %{repo: "acme/mom", actor_id: "bot", branch: "mom/1"}},
         {[:mom, :audit, :github_pr_failed], %{repo: "acme/mom", actor_id: "bot"}}
       ]}
    ]

    Enum.each(scenarios, fn {stop_point, events} ->
      assert {:error, signal} = IncidentToPr.evaluate(events)
      assert signal.stop_point_classification[stop_point] == :failed
      assert signal.failure_stop_point == stop_point
    end)
  end
end
