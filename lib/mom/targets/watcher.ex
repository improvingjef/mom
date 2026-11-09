defmodule Mom.Targets.Watcher do
  @moduledoc """
  Watches one target: runs a `Mom.Runner` loop with that target's
  `Mom.Config` and feeds `Mom.Status`.

  * Before each connect it sets the target's cookie for that node only
    (`:erlang.set_cookie/2`).
  * On each connect and reconnect it reads the app's project info
    (`:mom_info`) and, when the info has a `repo`, uses it as the target's
    GitHub repository for issues and fixes.
  * A node it cannot reach is `down`; the runner retries with exponential
    backoff and installs the handlers again on reconnect.
  * Triage `off` runs the pipeline with `Mom.Targets.RecordOnly`, which
    calls no agent.

  The runner traps exits and ignores them, so this process kills the runner
  (and the pipeline) itself when it stops.
  """

  use GenServer

  alias Mom.{Config, Runner, Status}
  alias Mom.Targets.{RecordOnly, ReportOnly, Target}

  require Logger

  @default_backoff {1_000, 30_000}
  @rpc_timeout_ms 5_000

  def child_spec({%Target{name: name}, _opts} = arg) do
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [arg]}}
  end

  def start_link({%Target{} = target, opts}) do
    GenServer.start_link(__MODULE__, {target, opts})
  end

  @impl true
  def init({%Target{} = target, opts}) do
    Process.flag(:trap_exit, true)
    :ok = Status.register(target.name)

    case build_config(target, nil, opts) do
      {:ok, config} ->
        {:links, before} = Process.info(self(), :links)

        case Runner.start(config, runner_opts(target, opts)) do
          {:ok, runner} ->
            # Runner.start links the pipeline and the runner loop to us.
            {:links, now} = Process.info(self(), :links)
            {:ok, %{target: target, runner: runner, owned: now -- before}}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        Logger.error("mom: target #{target.name} has an invalid config: #{reason}")
        :ok = Status.down(target.name, "config: #{reason}")
        {:ok, %{target: target, runner: nil, owned: []}}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    # gen_server handles the parent's exit itself. Other exits (for example
    # the port of a `System.cmd` in `Mom.Config.from_opts/1`) are ignored
    # unless they come from the runner or the pipeline.
    if pid in state.owned do
      {:stop, {:shutdown, {:runner_or_pipeline_exit, reason}}, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # The runner traps exits and would outlive us; stop it and the pipeline.
    Enum.each(state.owned, fn pid -> if is_pid(pid), do: Process.exit(pid, :kill) end)
    :ok
  end

  @doc """
  Options for `Mom.Config.from_opts/1` for a target. `github_repo` comes
  from the target's project info when known. Extra options from
  `opts[:config_opts]` (or `config :mom, :target_config_opts`) are merged
  last.
  """
  @spec config_opts(Target.t(), String.t() | nil, keyword()) :: keyword()
  def config_opts(%Target{} = target, github_repo, opts \\ []) do
    base = [
      repo: checkout_path(target),
      mode: :remote,
      node: target.node,
      # The cookie is set per node in the before_connect hook; Mom's own
      # cookie stays unchanged.
      cookie: nil,
      llm_provider: target.agent,
      triage_mode: if(target.triage == :fix, do: :fix, else: :report)
    ]

    base
    |> then(fn o -> if github_repo, do: Keyword.put(o, :github_repo, github_repo), else: o end)
    |> Keyword.merge(
      Keyword.get(opts, :config_opts, Application.get_env(:mom, :target_config_opts, []))
    )
  end

  @doc "Local checkout of the target's code: `<data_dir>/checkouts/<name>`."
  @spec checkout_path(Target.t()) :: String.t()
  def checkout_path(%Target{name: name}), do: Path.join([Mom.data_dir(), "checkouts", name])

  @doc """
  Turns a runner event message into a status record:
  `{:error, kind, message}`, `{:event, kind}` or `:ignore`.
  """
  @spec classify(term()) :: {:error, String.t(), String.t()} | {:event, String.t()} | :ignore
  def classify({:mom_log, %{level: level} = event}) do
    {:error, to_string(level), log_message(event)}
  end

  def classify({:mom_telemetry, %{event: [:phoenix, :router_dispatch, :exception], metadata: md}}) do
    {:error, "phoenix", exception_message(md[:reason], md[:kind])}
  end

  def classify({:mom_telemetry, %{event: [:oban, :job, :exception], metadata: md}}) do
    worker = if md[:worker], do: "#{md[:worker]}: ", else: ""
    {:error, "oban", worker <> exception_message(md[:error] || md[:reason], md[:kind])}
  end

  def classify({:mom_telemetry, %{event: event}}) when is_list(event) do
    {:event, Enum.map_join(event, ".", &to_string/1)}
  end

  def classify({:mom_system_monitor, %{type: type}}), do: {:event, "system_monitor.#{type}"}
  def classify(_message), do: :ignore

  # --- internals ---

  @doc false
  # Public for tests: what each triage mode gives the pipeline.
  def runner_opts(%Target{} = target, opts) do
    {base_ms, max_ms} =
      Keyword.get(opts, :backoff, Application.get_env(:mom, :target_backoff_ms, @default_backoff))

    worker_opts =
      case target.triage do
        :off -> [worker_module: RecordOnly]
        :report -> [worker_opts: [engine_module: ReportOnly]]
        :fix -> []
      end

    worker_opts ++
      [
        retry_connect: true,
        backoff: fn attempt -> min(base_ms * Integer.pow(2, min(attempt, 16)), max_ms) end,
        hooks: %{
          before_connect: fn -> set_cookie(target) end,
          on_connect: fn config -> on_connect(target, config, opts) end,
          on_down: fn _node -> Status.down(target.name) end,
          on_event: fn message -> record(target.name, message) end
        }
      ]
  end

  defp set_cookie(%Target{cookie: nil}), do: :ok

  defp set_cookie(%Target{node: node, cookie: cookie}) do
    if Node.alive?(), do: :erlang.set_cookie(node, cookie)
    :ok
  end

  defp on_connect(%Target{} = target, %Config{} = config, opts) do
    info = read_info(target.node)

    config =
      case info["repo"] do
        repo when is_binary(repo) and repo != "" and repo != config.governance.github_repo ->
          case build_config(target, repo, opts) do
            {:ok, new_config} ->
              new_config

            {:error, reason} ->
              Logger.warning("mom: target #{target.name}: repo #{repo} not used: #{reason}")
              config
          end

        _ ->
          config
      end

    :ok = Status.connected(target.name, info)
    config
  end

  defp build_config(target, github_repo, opts) do
    Config.from_opts(config_opts(target, github_repo, opts))
  end

  @doc false
  # `:application` rather than Elixir's `Application`, so it also works on a
  # node without Elixir loaded; the result is the same.
  def read_info(node) do
    case :rpc.call(node, :application, :get_all_env, [:mom_info], @rpc_timeout_ms) do
      list when is_list(list) ->
        Map.new(list, fn {key, value} -> {to_string(key), info_value(value)} end)

      _ ->
        %{}
    end
  end

  defp info_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp info_value(nil), do: nil
  defp info_value(value) when is_atom(value), do: Atom.to_string(value)

  defp info_value(value) do
    if is_list(value) and List.ascii_printable?(value),
      do: List.to_string(value),
      else: inspect(value)
  end

  defp record(name, message) do
    case classify(message) do
      {:error, kind, text} -> Status.error(name, kind, text)
      {:event, kind} -> Status.event(name, kind)
      :ignore -> :ok
    end
  rescue
    error ->
      Logger.warning("mom: status record failed: #{Exception.message(error)}")
      :ok
  end

  defp log_message(%{msg: msg} = event) do
    text =
      case msg do
        {:string, chardata} ->
          IO.chardata_to_string(chardata)

        {:report, report} ->
          inspect(report, limit: 20)

        {format, args} when is_list(args) ->
          format |> :io_lib.format(args) |> IO.chardata_to_string()

        other ->
          inspect(other)
      end

    case event do
      %{meta: %{crash_reason: {%{__exception__: true} = exception, _stack}}} ->
        exception_message(exception, :error) <> " " <> text

      _ ->
        text
    end
  rescue
    _ -> inspect(msg, limit: 20)
  end

  defp log_message(event), do: inspect(event, limit: 20)

  defp exception_message(%{__exception__: true, __struct__: module} = exception, _kind) do
    inspect(module) <> ": " <> Exception.message(exception)
  rescue
    _ -> inspect(exception, limit: 20)
  end

  defp exception_message(nil, kind), do: to_string(kind || "exception")
  defp exception_message(reason, _kind), do: inspect(reason, limit: 20)
end
