defmodule Mom.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The multi-target service (status, tokens, watchers, endpoint) runs only
    # with `config :mom, :service, true` (prod runtime). Tests and `mix mom`
    # start nothing here.
    children =
      if Application.get_env(:mom, :service, false), do: service_children(), else: []

    opts = [strategy: :one_for_one, name: Mom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  def service_children do
    [
      Mom.Status,
      Mom.Tokens,
      Mom.Targets.Supervisor,
      {Bandit,
       plug: Mom.Web.Router,
       scheme: :http,
       ip: Application.get_env(:mom, :http_ip, {0, 0, 0, 0}),
       port: Application.get_env(:mom, :port, 4400)}
    ]
  end
end
