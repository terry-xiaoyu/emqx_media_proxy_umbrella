import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :emqx_media_proxy, EmqxMediaProxy.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "emqx_media_proxy_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :emqx_media_proxy_web, EmqxMediaProxyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "GYWoMi9/hQ5xF9RWCiT7HB/lt40IZxTXnNpZ4hUxWQOyhF2DaXXCkw7W33ycsrKf",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# In test we don't send emails
config :emqx_media_proxy, EmqxMediaProxy.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
