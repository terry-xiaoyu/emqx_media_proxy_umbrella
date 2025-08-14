defmodule EmqxMediaRtp.TtsHandler do
  @moduledoc """
  This module forwards RTP audio streams to the Automatic Speech Recognition (TTS) service.
  It processes Opus audio packets and converts them to text.
  """

  use Membrane.Filter

  require Logger
  alias Membrane.{RemoteStream, Buffer, Pad}
  alias EmqxMediaRtp.{AliRealtimeTTS}

  @type provider_opts() :: AliRealtimeTTS.provider_opts()

  def_input_pad :input,
    accepted_format: _any,
    availability: :on_request

  def_output_pad :output,
    accepted_format: %RemoteStream{content_format: MPEG}

  def_options asr_provider: [
        spec: module(),
        default: AliRealtimeTTS,
        description: "Module that provides TTS functionality"
      ],
      asr_options: [
        spec: provider_opts(),
        default: %{id: nil},
        description: "Options for the TTS provider"
      ]

  @impl true
  def handle_init(ctx, opts) do
    Logger.info("Initializing TTS Handler with options: #{inspect(opts)}, context: #{inspect(ctx)}")
    #:erlang.process_flag(:trap_exit, true)
    {[], %{opts: opts, provider_pid: nil, ssrc: nil}}
  end

  @impl true
  def handle_stream_format(Pad.ref(:input, _ssrc), _stream_format, _ctx, state) do
    {[stream_format: {:output, %RemoteStream{content_format: MPEG}}], state}
  end

  @impl true
  def handle_setup(_ctx, %{opts: opts} = state) do
    asr_provider = opts.asr_provider
    asr_options = opts.asr_options

    case asr_provider.start_link(self(), asr_options) do
      {:ok, pid} ->
        Logger.debug("TTS provider started successfully: #{inspect(asr_provider)}, PID: #{inspect(pid)}")
        {[], %{state | provider_pid: pid}}

      {:error, reason} ->
        Logger.error("Failed to start TTS provider: #{inspect(reason)}")
        {[terminate: reason], state}
    end
  end

  @impl true
  def handle_pad_added({Pad, :input, ssrc}, _ctx, state) do
    Logger.info("TTS Pad added for SSRC: #{ssrc}")
    {[], maybe_save_ssrc(state, ssrc)}
  end

  @impl true
  def handle_buffer({Pad, :input, _ref}, %Buffer{payload: payload}, _ctx, %{provider_pid: pid} = state) do
    if payload == :complete do
      Logger.debug("Received complete signal in TTS Handler, finishing task")
      :ok = AliRealtimeTTS.finish(pid)
    else
      :ok = AliRealtimeTTS.tts(pid, payload)
    end
    #Logger.debug("Recognized text: #{text}")
    {[], state}
  end

  @impl true
  def handle_end_of_stream(_, _ctx, state) do
    Logger.debug("RTP stream terminated, stopping TTS Handler")
    {[terminate: :normal], state}
  end

  @impl true
  def handle_info({:tts_response, bin_outputs}, _ctx, state) do
    Logger.info("Received TTS response of size: #{byte_size(bin_outputs)}")
    {[buffer: {:output, %Buffer{payload: bin_outputs}}], state}
  end

  def handle_info(info, _ctx, state) do
    Logger.warning("Unhandled info message in TTS Handler: #{inspect(info)}")
    {[], state}
  end

  defp maybe_save_ssrc(state, ssrc) do
    case state do
      %{ssrc: nil} ->
        state |> Map.put(:ssrc, ssrc)
      %{ssrc: ^ssrc} ->
        state
      %{ssrc: oldssr} ->
        throw("SSRC mismatch: expected #{oldssr}, got #{ssrc}")
    end
  end
end
