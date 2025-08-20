defmodule EmqxMediaProxyWeb.WebrtcPipeline do
  require Logger
  use Membrane.Pipeline
  alias Membrane.WebRTC.PhoenixSignaling

  @ice_servers [%{urls: "stun:stun.l.google.com:19302"}]

  def start_link(options) do
    Membrane.Pipeline.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{opts: opts}}
  end

  @impl true
  def handle_child_notification({:new_track, {_id, _info}}, :demuxer, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_child_notification({:end_of_stream, track}, :webrtc, _ctx, state) do
    state = %{state | track => nil}

    if !state.audio_track && !state.video_track do
      {[terminate: :normal], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_info({:start_pipeline, unique_id}, _, state) do
    Logger.info("Received start_pipeline message with unique ID: #{unique_id}")
    # Here you can add logic to start the pipeline or handle the unique ID
    input_sg = PhoenixSignaling.new("#{unique_id}_egress")
    output_sg = PhoenixSignaling.new("#{unique_id}_ingress")

    video_pipeline =
      get_child(:webrtc_source)
      |> via_out(:output, options: [kind: :video])
      |> via_in(:input, options: [kind: :video])
      |> get_child(:webrtc_sink)
    audio_pipeline =
      get_child(:webrtc_source)
      |> via_out(:output, options: [kind: :audio])
      |> child(:opus_parser, Membrane.Opus.Parser)
      |> via_in(:input, options: [kind: :audio])
      |> get_child(:webrtc_sink)
    spec =[
      child(:webrtc_source, %Membrane.WebRTC.Source{
        signaling: input_sg,
        allowed_video_codecs: :vp8,
        ice_servers: @ice_servers
      }),
      child(:webrtc_sink, %Membrane.WebRTC.Sink{signaling: output_sg, video_codec: :vp8,
        ice_servers: @ice_servers}),
      # child(:webrtc_demuxer, Membrane.Matroska.Demuxer),
      # child(:webrtc_muxer, Membrane.Matroska.Muxer),
      video_pipeline,
      audio_pipeline
    ]
    {[spec: spec], state}
  end
end
