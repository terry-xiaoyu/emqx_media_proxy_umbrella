defmodule EmqxMediaProxy.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EmqxMediaProxy.Repo,
      {DNSCluster, query: Application.get_env(:emqx_media_proxy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: EmqxMediaProxy.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: EmqxMediaProxy.Finch}
      # Start a worker by calling: EmqxMediaProxy.Worker.start_link(arg)
      # {EmqxMediaProxy.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: EmqxMediaProxy.Supervisor)
  end
end
