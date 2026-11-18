defmodule Hangten.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      HangtenWeb.Telemetry,
      Hangten.Repo,
      {DNSCluster, query: Application.get_env(:hangten, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hangten.PubSub},
      # Start a worker by calling: Hangten.Worker.start_link(arg)
      # {Hangten.Worker, arg},
      # Start to serve requests, typically the last entry
      HangtenWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hangten.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if Application.get_env(:hangten, :seed_on_start, true) do
          {:ok, count} = Hangten.Seeds.run()
          Logger.info("Seeded #{count} sales rows")
        end

        {:ok, pid}

      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HangtenWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
