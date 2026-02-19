defmodule Mom.Acceptance.MomStressScript do
  def run do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Mom.Stress.run([
          "--events",
          "40",
          "--max-concurrency",
          "4",
          "--queue-max-size",
          "120",
          "--work-ms",
          "1",
          "--diagnostics-every",
          "5",
          "--timeout-ms",
          "8000",
          "--format",
          "json"
        ])
      end)

    marker =
      output
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "RESULT_JSON:"))

    result =
      case marker do
        nil -> %{"error" => "missing_result_marker"}
        value -> Jason.decode!(String.replace_prefix(value, "RESULT_JSON:", ""))
      end

    IO.puts("RESULT_JSON:" <> Jason.encode!(result))
  end
end

Mom.Acceptance.MomStressScript.run()
