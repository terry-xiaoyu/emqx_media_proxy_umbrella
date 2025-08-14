defmodule EmqxMediaRtp.TtsUDPSink do
  @moduledoc """
  Element that sends buffers received on the input pad over a UDP socket.
  """
  use Membrane.Sink
  require Logger

  alias Membrane.{Pad, Buffer}
  alias Membrane.UDP.{CommonSocketBehaviour, Socket}

  def_options destination_address: [
                spec: :inet.ip_address(),
                description: "An IP Address that the packets will be sent to."
              ],
              destination_port_no: [
                spec: :inet.port_number(),
                description: "A UDP port number of a target."
              ],
              local_address: [
                spec: :inet.socket_address(),
                default: :any,
                description: """
                An IP Address set for a UDP socket used to sent packets. It allows to specify which
                network interface to use if there's more than one.
                """
              ],
              local_port_no: [
                spec: :inet.port_number(),
                default: 0,
                description: """
                A UDP port number for the socket used to sent packets. If set to `0` (default)
                the underlying OS will assign a free UDP port.
                """
              ],
              local_socket: [
                spec: :gen_udp.socket() | nil,
                default: nil,
                description: """
                Already opened UDP socket, if provided it will be used instead of creating
                and opening a new one.
                """
              ]

  def_input_pad :input, accepted_format: _any, availability: :on_request

  # Private API

  @impl true
  def handle_init(_context, %__MODULE__{} = options) do
    %__MODULE__{
      destination_address: dst_address,
      destination_port_no: dst_port_no,
      local_address: local_address,
      local_port_no: local_port_no,
      local_socket: local_socket
    } = options

    state = %{
      dst_socket: %Socket{
        ip_address: dst_address,
        port_no: dst_port_no
      },
      local_socket: %Socket{
        ip_address: local_address,
        port_no: local_port_no,
        socket_handle: local_socket
      }
    }

    {[], state}
  end

  @impl true
  def handle_playing(_context, state) do
    {[], state}
  end

  @mtu 8500
  @impl true
  def handle_buffer({Pad, :input, _ssrc}, %Buffer{payload: payload}, _context, state) do
    %{dst_socket: dst_socket, local_socket: local_socket} = state
    if byte_size(payload) > @mtu do
      Logger.warning("Payload size exceeds MTU: #{byte_size(payload)} > #{@mtu}, partitioning payload")
      send_packets_in_chunks(payload, dst_socket, local_socket)
    else
      :ok = Socket.send(dst_socket, local_socket, payload)
    end
    {[], state}
  end

  @impl true
  defdelegate handle_setup(context, state), to: CommonSocketBehaviour

  defp send_packets_in_chunks(<<part1::binary-size(@mtu), rem::binary>>, dst_socket, local_socket) do
    :ok = Socket.send(dst_socket, local_socket, part1)
    send_packets_in_chunks(rem, dst_socket, local_socket)
  end
  defp send_packets_in_chunks(<<>>, _dst_socket, _local_socket), do: :ok
  defp send_packets_in_chunks(payload, dst_socket, local_socket) do
    :ok = Socket.send(dst_socket, local_socket, payload)
  end
end
