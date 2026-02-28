defmodule Mix.Tasks.Mom.Stress do
  use Mix.Task

  alias Mom.Pipeline

  @shortdoc "Generate synthetic burst events through the Mom pipeline"

  @moduledoc """
  Submit synthetic incidents quickly to validate queueing and bounded concurrency behavior.
  """

  @default_events 50
  @default_max_concurrency 4
  @default_queue_max_size 200
  @default_overflow_policy :drop_newest
  @default_work_ms 5
  @default_diagnostics_every 5
  @default_timeout_ms 15_000
  @default_format :text

  @type parse_result ::
          {:ok,
           %{
             events: pos_integer(),
             max_concurrency: non_neg_integer(),
             queue_max_size: pos_integer(),
             overflow_policy: :drop_newest | :drop_oldest,
             work_ms: non_neg_integer(),
             diagnostics_every: pos_integer(),
             timeout_ms: pos_integer(),
             format: :text | :json
           }}
          | {:error, String.t()}

  @impl true
  def run(args) do
    case parse_args(args) do
      {:ok, opts} ->
        result = run_stress(opts)
        emit_result(result, opts.format)

      {:error, reason} ->
        Mix.raise("mom.stress failed: #{reason}")
    end
  end

  @spec parse_args([String.t()]) :: parse_result()
  def parse_args(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: option_parser_spec())

    with {:ok, events} <- parse_pos_int(opts, :events, @default_events),
         {:ok, max_concurrency} <-
           parse_non_neg_int(opts, :max_concurrency, @default_max_concurrency),
         {:ok, queue_max_size} <- parse_pos_int(opts, :queue_max_size, @default_queue_max_size),
         {:ok, overflow_policy} <- parse_overflow_policy(opts),
         {:ok, work_ms} <- parse_non_neg_int(opts, :work_ms, @default_work_ms),
         {:ok, diagnostics_every} <-
           parse_pos_int(opts, :diagnostics_every, @default_diagnostics_every),
         {:ok, timeout_ms} <- parse_pos_int(opts, :timeout_ms, @default_timeout_ms),
         {:ok, format} <- parse_format(opts) do
      {:ok,
       %{
         events: events,
         max_concurrency: max_concurrency,
         queue_max_size: queue_max_size,
         overflow_policy: overflow_policy,
         work_ms: work_ms,
         diagnostics_every: diagnostics_every,
         timeout_ms: timeout_ms,
         format: format
       }}
    end
  end

  defp run_stress(opts) do
    {:ok, pipeline} =
      Pipeline.start_link(
        dispatch?: true,
        worker_module: __MODULE__.Worker,
        worker_opts: [work_ms: opts.work_ms],
        max_concurrency: opts.max_concurrency,
        queue_max_size: opts.queue_max_size,
        overflow_policy: opts.overflow_policy
      )

    started_at = System.monotonic_time(:millisecond)
    enqueue_counters = enqueue_events(pipeline, opts.events, opts.diagnostics_every)
    expected_done = enqueue_counters.accepted

    final_stats =
      case await_completion(pipeline, expected_done, opts.timeout_ms) do
        {:ok, stats} ->
          stats

        {:error, :timeout, stats} ->
          Mix.raise(
            "mom.stress timed out after #{opts.timeout_ms}ms waiting for #{expected_done} jobs; " <>
              "completed=#{stats.completed_count} failed=#{stats.failed_count} queue=#{stats.queue_depth}"
          )
      end

    elapsed_ms = max(System.monotonic_time(:millisecond) - started_at, 1)
    throughput_per_sec = Float.round(expected_done * 1000 / elapsed_ms, 2)

    %{
      events_submitted: opts.events,
      accepted: enqueue_counters.accepted,
      dropped_newest: enqueue_counters.dropped_newest,
      dropped_oldest: enqueue_counters.dropped_oldest,
      dropped_inflight: enqueue_counters.dropped_inflight,
      dropped_total:
        enqueue_counters.dropped_newest +
          enqueue_counters.dropped_oldest + enqueue_counters.dropped_inflight,
      completed: final_stats.completed_count,
      failed: final_stats.failed_count,
      queue_depth: final_stats.queue_depth,
      active_workers: final_stats.active_workers,
      max_concurrency: opts.max_concurrency,
      queue_max_size: opts.queue_max_size,
      overflow_policy: opts.overflow_policy,
      elapsed_ms: elapsed_ms,
      throughput_per_sec: throughput_per_sec
    }
  end

  defp enqueue_events(pipeline, event_count, diagnostics_every) do
    Enum.reduce(1..event_count, counters_template(), fn idx, counters ->
      job =
        if rem(idx, diagnostics_every) == 0 do
          {:diagnostics_event, %{seq: idx}, [:synthetic_pressure]}
        else
          {:error_event, %{id: "stress-#{idx}"}}
        end

      case Pipeline.enqueue(pipeline, job) do
        :ok ->
          %{counters | accepted: counters.accepted + 1}

        {:dropped, :newest} ->
          %{counters | dropped_newest: counters.dropped_newest + 1}

        {:dropped, :oldest} ->
          %{counters | dropped_oldest: counters.dropped_oldest + 1}

        {:dropped, :inflight} ->
          %{counters | dropped_inflight: counters.dropped_inflight + 1}
      end
    end)
  end

  defp counters_template do
    %{
      accepted: 0,
      dropped_newest: 0,
      dropped_oldest: 0,
      dropped_inflight: 0
    }
  end

  defp await_completion(pipeline, expected_done, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_completion(pipeline, expected_done, deadline)
  end

  defp do_await_completion(pipeline, expected_done, deadline_ms) do
    stats = Pipeline.stats(pipeline)
    done_count = stats.completed_count + stats.failed_count

    cond do
      done_count >= expected_done and stats.queue_depth == 0 and stats.active_workers == 0 ->
        {:ok, stats}

      System.monotonic_time(:millisecond) >= deadline_ms ->
        {:error, :timeout, stats}

      true ->
        Process.sleep(10)
        do_await_completion(pipeline, expected_done, deadline_ms)
    end
  end

  defp emit_result(result, :json) do
    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  end

  defp emit_result(result, :text) do
    IO.puts("mom stress summary")
    IO.puts("submitted=#{result.events_submitted} accepted=#{result.accepted}")

    IO.puts(
      "dropped newest=#{result.dropped_newest} oldest=#{result.dropped_oldest} inflight=#{result.dropped_inflight}"
    )

    IO.puts("completed=#{result.completed} failed=#{result.failed}")
    IO.puts("elapsed_ms=#{result.elapsed_ms} throughput_per_sec=#{result.throughput_per_sec}")
    IO.puts("RESULT_JSON:" <> Jason.encode!(normalize(result)))
  end

  defp parse_overflow_policy(opts) do
    case Keyword.get(opts, :overflow_policy, @default_overflow_policy) do
      :drop_newest -> {:ok, :drop_newest}
      "drop_newest" -> {:ok, :drop_newest}
      :drop_oldest -> {:ok, :drop_oldest}
      "drop_oldest" -> {:ok, :drop_oldest}
      _other -> {:error, "overflow_policy must be drop_newest or drop_oldest"}
    end
  end

  defp parse_format(opts) do
    case Keyword.get(opts, :format, @default_format) do
      :text -> {:ok, :text}
      "text" -> {:ok, :text}
      :json -> {:ok, :json}
      "json" -> {:ok, :json}
      _other -> {:error, "format must be text or json"}
    end
  end

  defp parse_pos_int(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp parse_non_neg_int(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, "#{key} must be a non-negative integer"}
    end
  end

  defp option_parser_spec do
    [
      events: :integer,
      max_concurrency: :integer,
      queue_max_size: :integer,
      overflow_policy: :string,
      work_ms: :integer,
      diagnostics_every: :integer,
      timeout_ms: :integer,
      format: :string
    ]
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

  defmodule Worker do
    @moduledoc false

    def perform({_event_type, _event}, opts) do
      maybe_sleep(opts)
      :ok
    end

    def perform({_event_type, _report, _issues}, opts) do
      maybe_sleep(opts)
      :ok
    end

    defp maybe_sleep(opts) do
      case Keyword.get(opts, :work_ms, 0) do
        value when is_integer(value) and value > 0 -> Process.sleep(value)
        _other -> :ok
      end
    end
  end
end
