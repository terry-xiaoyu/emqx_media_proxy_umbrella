defmodule EmqxMediaProxyWeb.WebrtcPipeline do
  require Logger
  use Membrane.Pipeline
  alias Membrane.WebRTC.PhoenixSignaling
  alias Membrane.{RawAudio, Pad}
  alias EmqxMediaRtp.{RtpOpusEncoder}
  alias EmqxRealtimeApi.{AsrHandler, TtsHandler, AliRealtimeASR, AliRealtimeTTS}
  alias Membrane.MP3.MAD
  alias Membrane.FFmpeg.SWResample.Converter

  @ice_servers [%{urls: "stun:stun.l.google.com:19302"}]
  @source_sample_rate 8_000
  @sink_sample_rate 48_000
  @large_capacity 1000_000_000

  def start_link(options) do
    Membrane.Pipeline.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{opts: opts}}
  end

  @impl true
  def handle_child_notification({:end_of_stream, _}, {elem, pipe_id}, _ctx, state)
      when elem == :webrtc_source or elem == :webrtc_sink or elem == :opus_parser do
    Logger.warning("End of stream received from webrtc element for pipe_id: #{pipe_id}, element: #{elem}")
    {[{:remove_children, [
        {:webrtc_source, pipe_id},
        {:webrtc_sink, pipe_id},
        {:opus_parser, pipe_id},
        {:asr_handler, pipe_id},
        {:tts_handler, pipe_id},
        {:mp3_decoder, pipe_id},
        {:converter, pipe_id},
        {:opus_encoder, pipe_id},
        {:realtimer, pipe_id}
      ]}], state}
  end

  def handle_child_notification(notification, child, _ctx, state) do
    Logger.warning("Unhandled child notification: #{inspect(notification)} from child: #{inspect(child)}")
    {[spec: []], state}
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(child, pad, _ctx, state) do
    Logger.info("Element #{inspect(child)} ended its stream, pad: #{inspect(pad)}")
    {[], state}
  end

  @impl true
  def handle_info({:start_pipeline, pipe_id}, _, state) do
    Logger.info("Started new WebRTC Pipeline: #{pipe_id}")
    # Here you can add logic to start the pipeline or handle the unique ID
    input_sg = PhoenixSignaling.new("#{pipe_id}_egress")
    output_sg = PhoenixSignaling.new("#{pipe_id}_ingress")

    video_pipeline =
      get_child({:webrtc_source, pipe_id})
      |> via_out(:output, options: [kind: :video])
      |> via_in(:input, options: [kind: :video])
      |> get_child({:webrtc_sink, pipe_id})
    audio_pipeline =
      get_child({:webrtc_source, pipe_id})
      |> via_out(:output, options: [kind: :audio])
      |> child({:opus_parser, pipe_id}, Membrane.Opus.Decoder)
      |> child({:asr_handler, pipe_id}, %AsrHandler{
        provider: AliRealtimeASR,
        provider_opts: %{id: pipe_id}
      })
      |> via_in(Pad.ref(:input, pipe_id))
      |> child({:tts_handler, pipe_id}, %TtsHandler{
        provider: AliRealtimeTTS,
        provider_opts: %{id: pipe_id, sample_rate: @source_sample_rate}
      })
      |> child({:mp3_decoder, pipe_id}, MAD.Decoder)
      |> child({:converter, pipe_id}, %Converter{
        input_stream_format: %RawAudio{channels: 1, sample_format: :s24le, sample_rate: @source_sample_rate},
        output_stream_format: %RawAudio{channels: 1, sample_format: :s16le, sample_rate: @sink_sample_rate}
      })
      |> child({:opus_encoder, pipe_id}, %RtpOpusEncoder{
        application: :audio,
        input_stream_format: %RawAudio{
          channels: 1,
          sample_format: :s16le,
          sample_rate: @sink_sample_rate
        }
      })
      # |> child({:audio_payloader, pipe_id}, Membrane.RTP.Opus.Payloader)
      # |> child({:audio_rtp_muxer, pipe_id}, %Membrane.RTP.Muxer{srtp: false})
      # |> child({:audio_sink, pipe_id}, %Membrane.UDP.Sink{
      #   destination_address: {127, 0, 0, 1},
      #   destination_port_no: 5004
      # })
      |> via_in(:input, options: [], toilet_capacity: @large_capacity)
      |> child({:realtimer, pipe_id}, Membrane.Realtimer)
      |> via_in(:input, options: [kind: :audio])
      |> get_child({:webrtc_sink, pipe_id})
    spec =[
      child({:webrtc_source, pipe_id}, %Membrane.WebRTC.Source{
        signaling: input_sg,
        allowed_video_codecs: :vp8,
        ice_servers: @ice_servers
      }),
      child({:webrtc_sink, pipe_id}, %Membrane.WebRTC.Sink{
        signaling: output_sg,
        video_codec: :vp8,
        ice_servers: @ice_servers
      }),
      video_pipeline,
      audio_pipeline
    ]
    {[spec: spec], state}
  end
end
