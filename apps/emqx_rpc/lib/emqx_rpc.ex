defmodule EmqxRpc do
  @moduledoc """
  Documentation for `EmqxRpc`.
  """
  alias EmqxRpc.MqttMessage

  def send_mqtt_message(clientid, topic, payload, flags) do
    message = MqttMessage.make_message(clientid, topic, payload, flags)
    call(:mqtt_pub, :emqx, :publish, [message])
  end

  def call(key, mod, fun, args) do
    :gen_rpc.call({emqx_node(), key}, mod, fun, args, :infinity)
  end

  defp emqx_node() do
    :'emqx@127.0.0.1'
  end
end
