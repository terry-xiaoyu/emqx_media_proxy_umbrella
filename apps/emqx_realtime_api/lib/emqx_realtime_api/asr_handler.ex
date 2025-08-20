defmodule EmqxRealtimeApi.AsrHandler do
  @moduledoc """
  This module forwards RTP audio streams to the Automatic Speech Recognition (ASR) service.
  It processes Opus audio packets and converts them to text.
  """

  use Membrane.Filter

  require Logger
  alias Membrane.{RawAudio, Pad, Buffer}
  alias EmqxMediaRtp.{AliRealtimeASR}

  @type provider_opts() :: AliRealtimeASR.provider_opts()

  def_input_pad :input,
    accepted_format: %RawAudio{},
    availability: :on_request

  def_output_pad :output,
    accepted_format: _any

  def_options provider: [
        spec: module(),
        default: AliRealtimeASR,
        description: "Module that provides ASR functionality"
      ],
      provider_opts: [
        spec: provider_opts(),
        default: %{id: nil},
        description: "Options for the ASR provider"
      ]

  @impl true
  def handle_init(_ctx, opts) do
    #:erlang.process_flag(:trap_exit, true)
    {[], %{opts: opts, provider_pid: nil, ssrc: nil, provider: opts.provider}}
  end

  @impl true
  def handle_setup(_ctx, %{opts: opts} = state) do
    provider = opts.provider
    provider_opts = opts.provider_opts

    case provider.start_link(self(), provider_opts) do
      {:ok, pid} ->
        Logger.debug("ASR provider started successfully: #{inspect(provider)}, PID: #{inspect(pid)}")
        {[], %{state | provider_pid: pid}}

      {:error, reason} ->
        Logger.error("Failed to start ASR provider: #{inspect(reason)}")
        {[terminate: reason], state}
    end
  end

  @impl true
  def handle_pad_added({Pad, :input, id}, _ctx, state) do
    Logger.info("ASR Pad added for: #{inspect(id)}")
    {[], state}
  end

  @impl true
  def handle_buffer({Pad, :input, _ref}, buffer, _ctx, %{provider_pid: pid, provider: provider} = state) do
    #Logger.info("Received buffer in ASR Handler, SSRC: #{inspect(buffer)}")
    ssrc = buffer.metadata.rtp.ssrc
    :ok = provider.recognize(pid, buffer.payload)
    #IO.puts("Recognized text: #{text}")
    {[], maybe_save_ssrc(state, ssrc)}
  end

  @impl true
  def handle_end_of_stream(_, _ctx, state) do
    IO.puts("RTP stream terminated")
    {[], state}
  end

  @impl true
  def handle_info({:llm_response, text}, _ctx, state) do
    Logger.info("#{inspect(self())}, Received LLM response")
    { if text == "" do
        []
      else
        [buffer: {:output, %Buffer{payload: text}}]
      end, state}
  end

  def handle_info({:llm_complete, _text}, _ctx, state) do
    Logger.info("#{inspect(self())}, Received LLM complete")
    {[buffer: {:output, %Buffer{payload: :complete}}], state}
  end

  @impl true
  def handle_info(info, _ctx, state) do
    Logger.warning("Unhandled info message in ASR Handler: #{inspect(info)}")
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
