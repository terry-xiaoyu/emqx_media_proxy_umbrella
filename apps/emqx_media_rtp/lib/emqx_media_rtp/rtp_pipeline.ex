defmodule EmqxMediaRtp.RtpPipeline do
  use Membrane.Pipeline

  require Logger

  alias Membrane.{Pad, RTP, UDP}
  alias EmqxMediaRtp.{RtpOpusDepayloader, RtpOpusDecoder, AsrHandler, TtsHandler, TtsUDPSink}

  @local_ip {127, 0, 0, 1}

  @impl true
  def handle_init(_ctx, opts) do
    %{audio_port: audio_port, secure?: secure?, srtp_key: srtp_key} = opts

    srtp =
      if secure? do
        [%ExLibSRTP.Policy{ssrc: :any_inbound, key: srtp_key}]
      else
        false
      end

    spec =
      {[
         child(:audio_src, %UDP.Source{
           local_port_no: audio_port,
           local_address: @local_ip
         })
         |> child(:audio_rtp_demuxer, %RTP.Demuxer{srtp: srtp})
       ], stream_sync: :sinks}
    {[spec: spec], %{audio_port: audio_port}}
  end

  @impl true
  def handle_child_notification(
    {:new_rtp_stream, %{ssrc: ssrc, payload_type: payload_type, extensions: extensions}},
    :audio_rtp_demuxer,
    _ctx,
    %{audio_port: audio_port} = state
  ) do
    IO.puts("New RTP stream detected: SSRC=#{ssrc}, Payload Type=#{payload_type}} Extensions=#{inspect(extensions)}")
    spec = [
      get_child(:audio_rtp_demuxer)
      |> via_out(:output, options: [stream_id: {:ssrc, ssrc}])
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:audio_depayloader, ssrc}, RtpOpusDepayloader)
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:audio_decoder, ssrc}, RtpOpusDecoder)
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:asr_handler, ssrc}, AsrHandler)
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:tts_handler, ssrc}, TtsHandler)
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:audio_sink, ssrc}, %TtsUDPSink{
        destination_address: @local_ip,
        destination_port_no: audio_port + 1
      })
    ]
    {[spec: spec], state}
  end

  def handle_child_notification(_notification, _child_name, _ctx, state) do
    {[], state}
  end

end
