defmodule EmqxMediaProxyWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :emqx_media_proxy_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {EmqxMediaProxyWeb.Application, []},
      extra_applications: [:logger, :runtime_tools, :membrane_webrtc_plugin]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20"},
      {:membrane_mp3_mad_plugin, "~> 0.18"},
      {:membrane_rtp_plugin, "~> 0.31"},
      {:emqx_media_proxy, in_umbrella: true},
      {:emqx_realtime_api, in_umbrella: true},
      {:membrane_matroska_plugin, "~> 0.6"},
      {:emqx_media_rtp, in_umbrella: true},
      {:membrane_core, "~> 1.2"},
      {:membrane_opus_plugin, "~> 0.20"},
      {:membrane_rtp_opus_plugin, "~> 0.10"},
      {:xav, "~> 0.11.0"},
      {:bumblebee, "~> 0.6.2"},
      {:membrane_webrtc_plugin, git: "https://github.com/terry-xiaoyu/membrane_webrtc_plugin.git", branch: "master"},
      {:phoenix, "~> 1.7.21"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2.0", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind emqx_media_proxy_web", "esbuild emqx_media_proxy_web"],
      "assets.deploy": [
        "tailwind emqx_media_proxy_web --minify",
        "esbuild emqx_media_proxy_web --minify",
        "phx.digest"
      ]
    ]
  end
end
