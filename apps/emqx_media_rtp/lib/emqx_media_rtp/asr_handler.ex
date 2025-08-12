defmodule EmqxMediaRtp.AsrHandler do
  @moduledoc """
  This module forwards RTP audio streams to the Automatic Speech Recognition (ASR) service.
  It processes Opus audio packets and converts them to text.
  """

  use Membrane.Sink

  require Logger
  alias Membrane.{RawAudio, Pad}
  alias EmqxMediaRtp.{AliRealtimeAsr}

  @type provider_opts() :: AliRealtimeAsr.provider_opts()

  def_input_pad :input,
    accepted_format: %RawAudio{},
    availability: :on_request

  def_options asr_provider: [
        spec: module(),
        default: AliRealtimeAsr,
        description: "Module that provides ASR functionality"
      ],
      asr_options: [
        spec: provider_opts(),
        default: %{},
        description: "Options for the ASR provider"
      ]

  @impl true
  def handle_init(_ctx, opts) do
    #:erlang.process_flag(:trap_exit, true)
    {[], %{opts: opts, provider_pid: nil, ssrc: nil}}
  end

  @impl true
  def handle_setup(_ctx, %{opts: opts} = state) do
    asr_provider = opts.asr_provider
    asr_options = opts.asr_options

    case asr_provider.start_link(asr_options) do
      {:ok, pid} ->
        Logger.debug("ASR provider started successfully: #{inspect(asr_provider)}, PID: #{inspect(pid)}")
        {[], %{state | provider_pid: pid}}

      {:error, reason} ->
        Logger.error("Failed to start ASR provider: #{inspect(reason)}")
        {[terminate: reason], state}
    end
  end

  @impl true
  def handle_pad_added({Pad, :input, ssrc}, _ctx, state) do
    Logger.info("Pad added for SSRC: #{ssrc}")
    {[], maybe_save_ssrc(state, ssrc)}
  end

  @impl true
  def handle_buffer({Pad, :input, _ref}, buffer, _ctx, %{provider_pid: pid} = state) do
    #IO.puts("Received buffer in ASR Handler, ref: #{inspect(_ref)}")
    ssrc = buffer.metadata.rtp.ssrc
    :ok = AliRealtimeAsr.recognize(pid, buffer.payload)
    #IO.puts("Recognized text: #{text}")
    {[], maybe_save_ssrc(state, ssrc)}
  end

  @impl true
  def handle_end_of_stream(_, _ctx, state) do
    IO.puts("RTP stream terminated, stopping ASR Handler")
    {[terminate: :normal], state}
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
