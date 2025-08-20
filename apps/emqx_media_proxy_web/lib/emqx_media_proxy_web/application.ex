defmodule EmqxMediaProxyWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  alias EmqxMediaProxyWeb.WebrtcPipeline

  @impl true
  def start(_type, _args) do
    children = [
      EmqxMediaProxyWeb.Telemetry,
      # Start a worker by calling: EmqxMediaProxyWeb.Worker.start_link(arg)
      # {EmqxMediaProxyWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      EmqxMediaProxyWeb.Endpoint,
      {DynamicSupervisor, name: EmqxMediaProxyWeb.DynSup, strategy: :one_for_one},
      {WebrtcPipeline, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EmqxMediaProxyWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EmqxMediaProxyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
