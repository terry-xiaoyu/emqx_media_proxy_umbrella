defmodule EmqxMediaRtp.RtpOpusDecoder do
  @moduledoc """
  This element performs decoding of Opus audio.
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{RTP, Opus, RemoteStream}
  alias Membrane.RawAudio

  def_options sample_rate: [
                spec: 8_000 | 12_000 | 16_000 | 24_000 | 48_000,
                default: 48_000,
                description: """
                Sample rate to decode at. Note: Opus is able to decode any stream
                at any supported sample rate. 48 kHz is recommended. For details,
                see https://tools.ietf.org/html/rfc7845#section-5.1 point 5.
                """
              ]

  def_input_pad :input,
    availability: :on_request,
    accepted_format:
      any_of(
        %RTP{},
        %Opus{self_delimiting?: false},
        %RemoteStream{type: :packetized, content_format: format} when format in [Opus, nil]
      )

  def_output_pad :output,
    accepted_format: %RawAudio{sample_format: :s16le}

  @impl true
  def handle_init(_ctx, %__MODULE__{} = options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{native: nil, channels: nil})

    {[], state}
  end

  @impl true
  def handle_stream_format({Pad, :input, _ref}, stream_format, ctx, state) do
    Opus.Decoder.handle_stream_format(:input, stream_format, ctx, state)
  end

  @impl true
  def handle_stream_format(_pad, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_added(pad, _ctx, state) do
    IO.inspect pad, label: "Pad added in RtpOpusDecoder"
    {[], state}
  end

  @impl true
  def handle_buffer({Pad, :input, _ref}, buffer, ctx, state) do
    Opus.Decoder.handle_buffer(:input, buffer, ctx, state)
  end

end
