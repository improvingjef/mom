defmodule Mom.Acceptance.MomCliConfigScript do
  def run do
    {:ok, config} =
      Mix.Tasks.Mom.parse_args([
        "/tmp/repo",
        "--mode",
        "inproc",
        "--max-concurrency",
        "7",
        "--queue-max-size",
        "280",
        "--job-timeout-ms",
        "15000",
        "--overflow-policy",
        "drop_oldest"
      ])

    result = %{
      mode: config.mode,
      max_concurrency: config.max_concurrency,
      queue_max_size: config.queue_max_size,
      job_timeout_ms: config.job_timeout_ms,
      overflow_policy: config.overflow_policy
    }

    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
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

Mom.Acceptance.MomCliConfigScript.run()
