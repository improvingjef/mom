defmodule Mix.Tasks.MomStressTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  require Logger

  test "parse_args accepts stress generation options" do
    {:ok, opts} =
      Mix.Tasks.Mom.Stress.parse_args([
        "--events",
        "25",
        "--max-concurrency",
        "5",
        "--queue-max-size",
        "300",
        "--overflow-policy",
        "drop_oldest",
        "--work-ms",
        "3",
        "--diagnostics-every",
        "4",
        "--timeout-ms",
        "9000",
        "--format",
        "json"
      ])

    assert opts.events == 25
    assert opts.max_concurrency == 5
    assert opts.queue_max_size == 300
    assert opts.overflow_policy == :drop_oldest
    assert opts.work_ms == 3
    assert opts.diagnostics_every == 4
    assert opts.timeout_ms == 9000
    assert opts.format == :json
  end

  test "parse_args rejects invalid overflow policy values" do
    assert {:error, "overflow_policy must be drop_newest or drop_oldest"} =
             Mix.Tasks.Mom.Stress.parse_args([
               "--overflow-policy",
               "invalid"
             ])
  end

  test "run emits result json for stress generation summary" do
    previous_level = Logger.level()

    output =
      try do
        Logger.configure(level: :emergency)

        capture_io(fn ->
          Mix.Tasks.Mom.Stress.run([
            "--events",
            "16",
            "--max-concurrency",
            "4",
            "--queue-max-size",
            "64",
            "--work-ms",
            "1",
            "--diagnostics-every",
            "4",
            "--timeout-ms",
            "5000",
            "--format",
            "json"
          ])
        end)
      after
        Logger.configure(level: previous_level)
      end

    marker = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "RESULT_JSON:"))
    assert marker

    {:ok, result} =
      marker
      |> String.replace_prefix("RESULT_JSON:", "")
      |> Jason.decode()

    assert result["events_submitted"] == 16
    assert result["completed"] == result["accepted"]
    assert result["failed"] == 0
  end
end
