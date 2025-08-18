defmodule EmqxMediaRtp.RtpPipeline do
  use Membrane.Pipeline

  require Logger

  alias Membrane.FFmpeg.SWResample.Converter
  alias Membrane.{RawAudio, Pad, RTP, UDP}
  alias Membrane.MP3.MAD
  alias EmqxMediaRtp.{RtpOpusDecoder, RtpOpusEncoder}
  alias EmqxRealtimeApi.{AsrHandler, TtsHandler, AliRealtimeASR, AliRealtimeTTS}

  @sample_rate 8_000

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
    {[spec: spec], %{audio_port: audio_port, srtp: srtp}}
  end

  @impl true
  def handle_child_notification(
    {:new_rtp_stream, %{ssrc: ssrc, payload_type: payload_type, extensions: extensions}},
    :audio_rtp_demuxer,
    _ctx,
    %{audio_port: audio_port, srtp: srtp} = state
  ) do
    IO.puts("New RTP stream detected: SSRC=#{ssrc}, Payload Type=#{payload_type}} Extensions=#{inspect(extensions)}")
    spec = [
      get_child(:audio_rtp_demuxer)
      |> via_out(:output, options: [stream_id: {:ssrc, ssrc}])
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:audio_decoder, ssrc}, RtpOpusDecoder)
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:asr_handler, ssrc}, %AsrHandler{
        provider: AliRealtimeASR,
        provider_opts: %{id: ssrc}
      })
      |> via_in(Pad.ref(:input, ssrc))
      |> child({:tts_handler, ssrc}, %TtsHandler{
        provider: AliRealtimeTTS,
        provider_opts: %{id: ssrc}
      })
      |> child({:mp3_decoder, ssrc}, MAD.Decoder)
      |> child({:converter, ssrc}, %Converter{
        input_stream_format: %RawAudio{channels: 1, sample_format: :s24le, sample_rate: @sample_rate},
        output_stream_format: %RawAudio{channels: 1, sample_format: :s16le, sample_rate: @sample_rate}
      })
      |> child({:opus_encoder, ssrc}, %RtpOpusEncoder{
        application: :audio,
        input_stream_format: %RawAudio{
          channels: 1,
          sample_format: :s16le,
          sample_rate: @sample_rate
        }
      })
      |> child({:audio_payloader, ssrc}, RTP.Opus.Payloader)
      |> child({:audio_rtp_muxer, ssrc}, %RTP.Muxer{srtp: srtp})
      #|> child({:audio_realtimer, ssrc}, Membrane.Realtimer)
      |> child({:audio_sink, ssrc}, %UDP.Sink{
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
