defmodule EmqxMediaRtp.RtpPipeline do
  use Membrane.Pipeline

  require Logger

  alias Membrane.{Pad, RTP, UDP}

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
        #  |> via_out(Pad.ref(:output, :no_ssrc), options: [stream_id: {:encoding_name, :opus}])
        #  |> via_in(Pad.ref(:input, :no_ssrc))
        #  |> child(:audio_depayloader, EmqxMediaRtp.RtpOpusDepayloader)
        #  |> via_in(Pad.ref(:input, :no_ssrc))
        #  |> child(:audio_decoder, EmqxMediaRtp.RtpOpusDecoder)
        #  |> via_in(Pad.ref(:input, :no_ssrc))
        #  |> child(:auto_speech_recognizer, EmqxMediaRtp.AsrHandler)
       ], stream_sync: :sinks}
    {[spec: spec], %{}}
  end

  @impl true
  def handle_child_notification(
    {:new_rtp_stream, %{ssrc: ssrc, payload_type: payload_type, extensions: extensions}},
    :audio_rtp_demuxer,
    _ctx,
    state
  ) do
    IO.puts("New RTP stream detected: SSRC=#{ssrc}, Payload Type=#{payload_type}} Extensions=#{inspect(extensions)}")
    spec = [
      get_child(:audio_rtp_demuxer)
      |> via_out(:output, options: [stream_id: {:ssrc, ssrc}])
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:audio_depayloader, ssrc}, EmqxMediaRtp.RtpOpusDepayloader)
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:audio_decoder, ssrc}, EmqxMediaRtp.RtpOpusDecoder)
      |> via_in(Pad.ref(:input, ssrc))
      |> child(EmqxMediaRtp.AsrHandler)
    ]
    {[spec: spec], state}
  end

  def handle_child_notification(_notification, _child_name, _ctx, state) do
    {[], state}
  end

end
