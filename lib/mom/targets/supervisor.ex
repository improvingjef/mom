defmodule Mom.Targets.Supervisor do
  @moduledoc """
  Runs one `Mom.Targets.Watcher` per target.

  Targets come from `opts[:targets]` (a list of `Mom.Targets.Target`), else
  from configuration (`Mom.Targets.from_config/0`). An invalid list stops
  the start: a bad `MOM_TARGETS` must not go unnoticed.
  """

  use Supervisor

  alias Mom.Targets

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    targets =
      case Keyword.fetch(opts, :targets) do
        {:ok, targets} ->
          targets

        :error ->
          case Targets.from_config() do
            {:ok, targets} -> targets
            {:error, reason} -> raise ArgumentError, reason
          end
      end

    watcher_opts = Keyword.take(opts, [:config_opts, :backoff])
    children = Enum.map(targets, &{Targets.Watcher, {&1, watcher_opts}})

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end
end
