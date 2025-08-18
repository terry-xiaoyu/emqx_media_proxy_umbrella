defmodule EmqxMediaProxy.Repo do
  use Ecto.Repo,
    otp_app: :emqx_media_proxy,
    adapter: Ecto.Adapters.Postgres
end
