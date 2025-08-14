defmodule EmqxMediaRtp.MixProject do
  use Mix.Project

  def project do
    [
      app: :emqx_media_rtp,
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
      mod: {EmqxMediaRtp.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:emqx_rpc, in_umbrella: true},
      {:langchain, "0.4.0-rc.1"},
      {:mint_web_socket, "~> 1.0"},
      {:membrane_tee_plugin, "~> 0.12" },
      {:membrane_core, "~> 1.2"},
      {:membrane_rtp_plugin, "~> 0.31"},
      {:membrane_udp_plugin, "~> 0.14"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.31.6"},
      {:membrane_h26x_plugin, "~> 0.10"},
      {:membrane_rtp_h264_plugin, "~> 0.20"},
      {:membrane_opus_plugin, "~> 0.20"},
      {:membrane_rtp_opus_plugin, "~> 0.10"},
      {:membrane_sdl_plugin, "~> 0.18.2"},
      {:membrane_portaudio_plugin, "~> 0.19"},
      {:membrane_file_plugin, "~> 0.17"},
      {:membrane_realtimer_plugin, "~> 0.10"},
      {:membrane_mp3_mad_plugin, "~> 0.18"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20"},
      {:ex_libsrtp, "~> 0.7"}
    ]
  end
end
