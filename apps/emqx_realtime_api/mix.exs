defmodule EmqxRealtimeApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :emqx_realtime_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {EmqxRealtimeApi.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:emqx_rpc, in_umbrella: true},
      {:elixir_uuid, "~> 1.2"},
      {:jason, "~> 1.2"},
      {:membrane_core, "~> 1.2"},
      {:membrane_raw_audio_format, "~> 0.12.0"},
      {:mint_web_socket, "~> 1.0"},
      {:langchain, "0.4.0-rc.1"}
    ]
  end
end
