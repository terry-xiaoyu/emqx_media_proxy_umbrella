defmodule EmqxMediaProxyWeb.WebRTCRoom do
  @moduledoc """
  This module is deprecated and will be removed.
  """
  require Logger
  require Membrane.Pad
  use EmqxMediaProxyWeb, :channel

  alias ExWebRTC.{
    ICECandidate,
    MediaStreamTrack,
    PeerConnection,
    RTPCodecParameters,
    SessionDescription,
    RTP
  }
  alias EmqxRealtimeApi.{AliRealtimeASR, AliRealtimeTTS}
  alias EmqxMediaRtp.RtpOpusEncoder
  alias Membrane.FFmpeg.SWResample.Converter
  alias Membrane.{Pad, RTP, Buffer, Opus, RawAudio}
  alias Membrane.MP3.MAD

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  @channels 2
  @sample_rate 48_000
  @tts_sample_rate 8_000
  @video_codecs [
    %RTPCodecParameters{
      payload_type: 96,
      mime_type: "video/VP8",
      clock_rate: 90_000
    }
  ]

  @audio_codecs [
    %RTPCodecParameters{
      payload_type: 111,
      mime_type: "audio/opus",
      clock_rate: @sample_rate,
      channels: @channels
    }
  ]

  @impl true
  def handle_info({:ex_webrtc, _from, msg}, socket) do
    handle_webrtc_msg(msg, socket)
  end

  def handle_info({:EXIT, pc, reason}, %{assigns: %{peer_connection: pc}} = socket) do
    # Bandit traps exits under the hood so our PeerConnection.start_link
    # won't automatically bring this process down.
    Logger.info("Peer connection process exited, reason: #{inspect(reason)}")
    {:stop, {:shutdown, :pc_closed}, socket}
  end

  def handle_info({:llm_response, text}, socket) do
    :ok = AliRealtimeTTS.tts(socket.assigns.tts_handler, text)
    Logger.info("#{inspect(self())}, Received LLM response: #{text}")
    {:noreply, socket}
  end

  def handle_info({:llm_complete, text}, socket) do
    :ok = AliRealtimeTTS.finish(socket.assigns.tts_handler)
    Logger.info("#{inspect(self())}, Received LLM complete: #{text}")
    {:noreply, socket}
  end

  def handle_info({:tts_response, mp3_packet}, socket) do
    Logger.info("#{inspect(self())}, Received TTS response with #{byte_size(mp3_packet)} packets")
    {actions, mp3_decoder_state} = MAD.Decoder.handle_buffer(
      :input,
      %Buffer{payload: mp3_packet},
      %{pads: %{output: %{stream_format: %RawAudio{
        sample_format: :s24le,
        sample_rate: @tts_sample_rate,
        channels: 1
      }}}},
      socket.assigns.mp3_decoder_state
    )
    {:output, %Buffer{payload: raw_packet}} = actions[:buffer]
    {actions, resampler_state} = Converter.handle_buffer(
      :input,
      %Buffer{payload: raw_packet, pts: nil},
      nil,
      socket.assigns.resampler_state
    )
    {:output, %Buffer{payload: resampled_packet}} = actions[:buffer]
    {actions, opus_encoder_state} = RtpOpusEncoder.handle_buffer(
      :input,
      %Buffer{payload: resampled_packet},
      nil,
      socket.assigns.opus_encoder_state
    )
    case actions[:buffer] do
      nil ->
        {:noreply, assign(socket, opus_encoder_state: opus_encoder_state)}
      {:output, %Buffer{payload: opus_payload, pts: pts}} ->
        #IO.puts("Sending RTP packet with payload: #{inspect(buffer)}")

        {actions, opus_muxer_state} = RTP.Muxer.handle_buffer(
          Pad.ref(:input, socket.assigns.in_audio_track_id),
          %Buffer{payload: opus_payload, pts: pts},
          nil,
          socket.assigns.opus_muxer_state
        )
        {:output, %Buffer{payload: rtp_packet, metadata: _metadata}} = actions[:buffer]
        :ok = PeerConnection.send_rtp(socket.assigns.peer_connection, socket.assigns.out_audio_track_id, rtp_packet)
        send_udp_test(rtp_packet)

        {:noreply, assign(socket, [
          mp3_decoder_state: mp3_decoder_state,
          opus_encoder_state: opus_encoder_state,
          resampler_state: resampler_state,
          opus_muxer_state: opus_muxer_state
        ])}
    end
  end

  def handle_info(info, socket) do
    Logger.warning("Unhandled info message: #{inspect(info)}")
    {:noreply, socket}
  end

  @impl true
  def terminate(reason, _socket) do
    Logger.info("Channel connection was terminated, reason: #{inspect(reason)}")
  end

  ######

  @impl true
  def join("room:" <> topic, payload, socket) do
    IO.puts "Joining room: #{topic} with payload: #{inspect(payload)}"
    {:ok, pc} =
      PeerConnection.start_link(
        ice_servers: @ice_servers,
        video_codecs: @video_codecs,
        audio_codecs: @audio_codecs
      )

    stream_id = MediaStreamTrack.generate_stream_id()
    video_track = MediaStreamTrack.new(:video, [stream_id])
    audio_track = MediaStreamTrack.new(:audio, [stream_id])

    {:ok, _sender} = PeerConnection.add_track(pc, video_track)
    {:ok, _sender} = PeerConnection.add_track(pc, audio_track)

    assigns = %{
      peer_connection: pc,
      out_video_track_id: video_track.id,
      out_audio_track_id: audio_track.id,
      in_video_track_id: nil,
      in_audio_track_id: nil
    }

    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_in("signaling", payload, socket) do
    #IO.puts "Received message: #{inspect(payload)}"
    handle_signaling(payload, socket)
    #broadcast!(socket, "signaling", {:binary, payload})
    {:noreply, socket}
  end

  defp handle_signaling(%{"type" => "offer", "data" => data}, socket) do
    Logger.info("Received SDP offer:\n#{data["sdp"]}")

    pc = socket.assigns.peer_connection
    offer = SessionDescription.from_json(data)
    :ok = PeerConnection.set_remote_description(pc, offer)

    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)

    answer_json = SessionDescription.to_json(answer)
    msg = %{"type" => "answer", "data" => answer_json}
    Logger.info("Sent SDP answer:\n#{answer_json["sdp"]}")
    push(socket, "signaling", msg)
  end

  defp handle_signaling(%{"type" => "ice", "data" => data}, socket) do
    Logger.info("Received ICE candidate: #{data["candidate"]}")

    pc = socket.assigns.peer_connection
    candidate = ICECandidate.from_json(data)
    :ok = PeerConnection.add_ice_candidate(pc, candidate)
  end

  defp handle_webrtc_msg({:connection_state_change, conn_state}, socket) do
    Logger.info("Connection state changed: #{conn_state}")

    if conn_state == :failed do
      {:stop, {:shutdown, :pc_failed}, socket}
    else
      {:noreply, socket}
    end
  end

  defp handle_webrtc_msg({:ice_candidate, candidate}, socket) do
    candidate_json = ICECandidate.to_json(candidate)
    Logger.info("Sent ICE candidate: #{candidate_json["candidate"]}")
    msg = %{"type" => "ice", "data" => candidate_json}
    push(socket, "signaling", msg)
    {:noreply, socket}
  end

  defp handle_webrtc_msg({:track, track}, socket) do
    %MediaStreamTrack{kind: kind, id: id} = track
    Logger.info("Received track: #{kind} with ID: #{id}")
    case kind do
      :video ->
        {:noreply, assign(socket, :in_video_track_id, id)}
      :audio ->
        with {:ok, asr_pid} <- AliRealtimeASR.start_link(self(), %{id: id}),
             {:ok, tts_pid} <- AliRealtimeTTS.start_link(self(), %{id: id, sample_rate: @tts_sample_rate, format: "mp3"}) do
            Logger.info("#{inspect(self())} - ASR provider started successfully, PID: #{inspect(asr_pid)}")
            {_, mp3_decoder_state} = MAD.Decoder.handle_init(nil, %{})
            {_, mp3_decoder_state} = MAD.Decoder.handle_playing(nil, mp3_decoder_state)
            {_, opus_encoder_state} = RtpOpusEncoder.handle_setup(nil, %{
                application: :audio,
                bitrate: :auto,
                signal_type: :auto,
                input_stream_format: %RawAudio{
                  channels: 1,
                  sample_format: :s16le,
                  sample_rate: @tts_sample_rate
                },
                current_pts: nil,
                native: nil,
                queue: <<>>
              })
            {_, resampler_state} = Converter.handle_init(nil, %Converter{
              input_stream_format: %RawAudio{channels: 1, sample_format: :s24le, sample_rate: @tts_sample_rate},
              output_stream_format: %RawAudio{channels: 1, sample_format: :s16le, sample_rate: @sample_rate}
            })
            {_, resampler_state} = Converter.handle_setup(nil, resampler_state)
            {_, opus_muxer_state} = RTP.Muxer.handle_init(nil, %RTP.Muxer{
              srtp: false,
              payload_type_mapping: %{}
            })
            pad_opts = %{options: %{ssrc: :random, encoding: "opus", payload_type: nil, clock_rate: @sample_rate}}
            {_, opus_muxer_state} = RTP.Muxer.handle_stream_format(
              Pad.ref(:input, id),
              %{
                payload_format: Membrane.Opus
              },
              %{pads: %{Pad.ref(:input, id) => pad_opts}},
              opus_muxer_state
            )
            {:noreply, assign(socket, %{
              in_audio_track_id: id,
              asr_handler: asr_pid,
              tts_handler: tts_pid,
              mp3_decoder_state: mp3_decoder_state,
              opus_decoder_state: %{
                sample_rate: @sample_rate,
                channels: nil,
                native: nil
              },
              opus_encoder_state: opus_encoder_state,
              resampler_state: resampler_state,
              opus_muxer_state: opus_muxer_state
            })}
        else
          {:error, reason} ->
            Logger.error("Failed to start ASR provider: #{inspect(reason)}")
            {:stop, {:shutdown, reason}, socket}
        end
    end
  end

  defp handle_webrtc_msg({:rtcp, _packets}, socket) do
    {:noreply, socket}
  end

  defp handle_webrtc_msg({:rtp, id, nil, packet}, %{assigns: %{in_audio_track_id: id, asr_handler: asr_pid, opus_decoder_state: opus_decoder_state}} = socket) do
    #Logger.info("Received RTP packet for audio track #{id}, sending to ASR handler, packet: #{inspect(Map.delete(packet, :payload))}")
    {actions, opus_decoder_state} = Opus.Decoder.handle_buffer(:input, %Buffer{payload: packet.payload}, nil, opus_decoder_state)
    case actions[:buffer] do
      nil -> :ok
      {:output, %Buffer{payload: payload}} ->
        AliRealtimeASR.recognize(asr_pid, payload)
        #Logger.info("Sent audio packet to ASR handler, packet: #{inspect(packet)}")
        #PeerConnection.send_rtp(socket.assigns.peer_connection, socket.assigns.out_audio_track_id, packet)
    end
    {:noreply, assign(socket, [opus_decoder_state: opus_decoder_state])}
  end

  defp handle_webrtc_msg({:rtp, id, _rid, packet}, %{assigns: %{in_video_track_id: id}} = socket) do
    #Logger.info("Received RTP packet for video track #{id}, rid: #{inspect(rid)}")
    pc = socket.assigns.peer_connection
    out_video_track_id = socket.assigns.out_video_track_id
    PeerConnection.send_rtp(pc, out_video_track_id, packet)
    {:noreply, socket}
  end

  defp handle_webrtc_msg(msg, socket) do
    Logger.warning("Unhandled WebRTC message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp send_udp_test(rtp_packet) do
    # This is a test function to send RTP packets via UDP
    # You can implement your UDP sending logic here
    dst_address = {127, 0, 0, 1}
    dst_port_no = 5003
    local_port_no = 0

    case Process.get(:udp_socket) do
      nil ->
        {:ok, socket} = :gen_udp.open(local_port_no, [:binary, {:active, false}])
        Process.put(:udp_socket, socket)
        :ok = :gen_udp.send(socket, dst_address, dst_port_no, rtp_packet)
      socket ->
        :ok = :gen_udp.send(socket, dst_address, dst_port_no, rtp_packet)
    end
  end

end
