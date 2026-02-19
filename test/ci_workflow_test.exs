defmodule Mom.CIWorkflowTest do
  use ExUnit.Case, async: true

  alias Mom.CIWorkflow

  test "verify_required_checks validates workflow names and playwright reliability controls" do
    workflows_path = unique_workflows_path()
    File.mkdir_p!(workflows_path)

    File.write!(
      Path.join(workflows_path, "ci-exunit.yml"),
      """
      name: ci/exunit
      on:
        pull_request:
        push:
      jobs:
        exunit:
          name: ci/exunit
          runs-on: ubuntu-latest
          steps:
            - run: mix test
      """
    )

    File.write!(
      Path.join(workflows_path, "ci-playwright.yml"),
      """
      name: ci/playwright
      on:
        pull_request:
        push:
      jobs:
        playwright:
          name: ci/playwright
          runs-on: ubuntu-latest
          steps:
            - run: npm run test:ci --prefix acceptance
              env:
                MOM_ACCEPTANCE_FAIL_ON_FLAKY: "true"
                MOM_ACCEPTANCE_CONCURRENCY_REPORT_PATH: acceptance/.artifacts/concurrency-report.json
            - uses: actions/upload-artifact@v4
              with:
                name: acceptance-concurrency-report
                path: acceptance/.artifacts/concurrency-report.json
      """
    )

    assert {:ok, evidence} =
             CIWorkflow.verify_required_checks(
               ["ci/exunit", "ci/playwright"],
               workflows_path: workflows_path
             )

    assert evidence.playwright_fail_on_flaky
    assert evidence.playwright_concurrency_report_path_set
    assert evidence.playwright_concurrency_artifact_uploaded
  end

  test "verify_required_checks fails when required workflow check is missing" do
    workflows_path = unique_workflows_path()
    File.mkdir_p!(workflows_path)

    File.write!(
      Path.join(workflows_path, "ci-exunit.yml"),
      """
      name: ci/exunit
      jobs:
        exunit:
          name: ci/exunit
          runs-on: ubuntu-latest
          steps:
            - run: mix test
      """
    )

    assert {:error, reason} =
             CIWorkflow.verify_required_checks(
               ["ci/exunit", "ci/playwright"],
               workflows_path: workflows_path
             )

    assert reason =~ "missing required workflow checks"
    assert reason =~ "ci/playwright"
  end

  test "verify_required_checks fails when playwright workflow does not enforce fail-on-flaky policy" do
    workflows_path = unique_workflows_path()
    File.mkdir_p!(workflows_path)

    File.write!(
      Path.join(workflows_path, "ci-exunit.yml"),
      """
      name: ci/exunit
      jobs:
        exunit:
          name: ci/exunit
          runs-on: ubuntu-latest
          steps:
            - run: mix test
      """
    )

    File.write!(
      Path.join(workflows_path, "ci-playwright.yml"),
      """
      name: ci/playwright
      jobs:
        playwright:
          name: ci/playwright
          runs-on: ubuntu-latest
          steps:
            - run: npm run test:ci --prefix acceptance
      """
    )

    assert {:error, reason} =
             CIWorkflow.verify_required_checks(
               ["ci/exunit", "ci/playwright"],
               workflows_path: workflows_path
             )

    assert reason =~ "MOM_ACCEPTANCE_FAIL_ON_FLAKY"
  end

  defp unique_workflows_path do
    Path.join(
      System.tmp_dir!(),
      "mom-ci-workflows-#{System.unique_integer([:positive])}"
    )
  end
end
