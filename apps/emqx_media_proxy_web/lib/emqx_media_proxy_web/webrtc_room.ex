defmodule EmqxMediaProxyWeb.WebRTCRoom do
  require Logger
  use EmqxMediaProxyWeb, :channel
  require Membrane.Pad

  alias ExWebRTC.{
    ICECandidate,
    MediaStreamTrack,
    PeerConnection,
    RTPCodecParameters,
    SessionDescription
  }
  alias EmqxRealtimeApi.{AliRealtimeASR, AliRealtimeTTS}
  alias EmqxMediaRtp.RtpOpusEncoder
  alias Membrane.{Pad, Buffer, Opus, RawAudio}

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  @channels 2
  @sample_rate 48_000
  @clock_rate 90_000
  @video_codecs [
    %RTPCodecParameters{
      payload_type: 96,
      mime_type: "video/VP8",
      clock_rate: @clock_rate
    }
  ]

  @audio_codecs [
    %RTPCodecParameters{
      payload_type: 111,
      mime_type: "audio/opus",
      clock_rate: @clock_rate,
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

  def handle_info({:tts_response, audio_packet}, socket) do
    Logger.info("#{inspect(self())}, Received TTS response with #{byte_size(audio_packet)} packets")
    pc = socket.assigns.peer_connection
    out_audio_track_id = socket.assigns.out_audio_track_id
    in_audio_track_id = socket.assigns.in_audio_track_id
    {actions, opus_encoder_state} = RtpOpusEncoder.handle_buffer(
      :input,
      %Buffer{payload: audio_packet},
      nil,
      socket.assigns.opus_encoder_state
    )
    case actions[:buffer] do
      nil ->
        {:noreply, assign(socket, opus_encoder_state: opus_encoder_state)}
      {:output, buffer} ->
        {actions, rtp_muxer_state} = Membrane.RTP.Muxer.handle_buffer(
          Pad.ref(:input, in_audio_track_id), buffer, nil, socket.assigns.rtp_muxer_state)
        {:output, buffer} = actions[:buffer]
        #IO.puts("Decoded audio opus_packet of size: #{byte_size(payload)}")
        :ok = PeerConnection.send_rtp(pc, out_audio_track_id, buffer.payload)
        {:noreply, assign(socket, [
          opus_encoder_state: opus_encoder_state,
          rtp_muxer_state: rtp_muxer_state
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
             {:ok, tts_pid} <- AliRealtimeTTS.start_link(self(), %{id: id}) do
            Logger.info("#{inspect(self())} - ASR provider started successfully, PID: #{inspect(asr_pid)}")
            {_, opus_encoder_state} = RtpOpusEncoder.handle_setup(nil, %{
                application: :audio,
                bitrate: :auto,
                signal_type: :auto,
                input_stream_format: %RawAudio{
                  channels: 1,
                  sample_format: :s16le,
                  sample_rate: 8_000
                },
                current_pts: nil,
                native: nil,
                queue: <<>>
              })
            {_, rtp_muxer_state} = Membrane.RTP.Muxer.handle_init(nil, %{
              payload_type_mapping: %{},
              srtp: false
            })
            pad = Pad.ref(:input, id)
            ctx = %{pads: %{pad => %{options: %{ssrc: id, encoding: nil, payload_type: 111, clock_rate: @clock_rate}}}}
            {[], rtp_muxer_state} = Membrane.RTP.Muxer.handle_stream_format(pad, %{payload_format: :opus}, ctx, rtp_muxer_state)
            {:noreply, assign(socket, %{
              in_audio_track_id: id,
              asr_handler: asr_pid,
              tts_handler: tts_pid,
              opus_decoder_state: %{
                sample_rate: @sample_rate,
                channels: nil,
                native: nil
              },
              opus_encoder_state: opus_encoder_state,
              rtp_muxer_state: rtp_muxer_state
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
    #Logger.info("Received RTP packet for audio track #{id}, sending to ASR handler, packet: #{inspect(packet)}")
    {actions, opus_decoder_state} = Opus.Decoder.handle_buffer(:input, %Buffer{payload: packet.payload}, nil, opus_decoder_state)
    case actions[:buffer] do
      nil -> :ok
      {:output, %Buffer{payload: payload}} ->
        AliRealtimeASR.recognize(asr_pid, payload)
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

end
