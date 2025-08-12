defmodule EmqxRpc.MqttMessage do
  @moduledoc """
  Module for handling MQTT messages in the EMQX RPC context.
  """
  require Record
  alias UUID

  Record.defrecord(:message, [
    id: nil,
    qos: 0,
    from: nil,
    flags: %{},
    headers: %{},
    topic: nil,
    payload: nil,
    timestamp: nil,
    extra: %{}
  ])

  def make_message(clientid, topic, payload, flags) do
    message(
      id: UUID.uuid4(),
      qos: flags.qos,
      from: clientid,
      flags: flags,
      headers: %{},
      topic: topic,
      payload: payload,
      timestamp: :erlang.system_time(:millisecond)
    )
  end

end
