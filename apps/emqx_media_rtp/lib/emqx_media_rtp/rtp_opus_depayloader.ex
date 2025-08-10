defmodule EmqxMediaRtp.RtpOpusDepayloader do
  use Membrane.Filter

  alias Membrane.{Opus, RemoteStream, RTP, Pad}

  def_input_pad :input,
    availability: :on_request,
    accepted_format: %RTP{payload_format: format} when format in [nil, Opus]

  def_output_pad :output,
    accepted_format: %RemoteStream{type: :packetized, content_format: Opus}

  @impl true
  def handle_stream_format({Pad, :input, _ref}, _stream_format, _context, state) do
    {
      [stream_format: {:output, %RemoteStream{type: :packetized, content_format: Opus}}],
      state
    }
  end

  @impl true
  def handle_stream_format(_pad, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_added(pad, _ctx, state) do
    IO.inspect pad, label: "Pad added in ASR Handler"
    {[], state}
  end

  @impl true
  def handle_buffer({Pad, :input, _ref}, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end
end
