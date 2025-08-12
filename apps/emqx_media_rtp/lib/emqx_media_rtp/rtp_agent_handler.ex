defmodule EmqxMediaRtp.RtpAgentHandler do
  @moduledoc """
  This module callbacks the audio/video agents and handles their responses.
  """

  alias LangChain.{Message, MessageDelta}
  alias LangChain.ChatModels.{ChatOpenAI}
  alias LangChain.Chains.LLMChain
  alias LangChain.Utils.ChainResult

  def handle_asr_results(results) when is_list(results) do
    text = Enum.join(results, " ")
    IO.puts("ASR Result: #{text}")
    send_mqtt_message(%{"text" => text})
  end

  def notify_llm_begin() do
    send_mqtt_message(%{"llm" => "$llm_begin$"})
  end

  def notify_llm_end() do
    send_mqtt_message(%{"llm" => "$llm_end$"})
  end

  def send_llm_full(text) do
    send_mqtt_message(%{"full_llm" => text})
  end

  def request_llm(text) do
    IO.puts "Requesting LLM with text: #{text}"
    handler = %{
      on_llm_new_delta: fn _model, data_list ->
        # we received a piece of data
        Enum.each(data_list, fn %MessageDelta{content: content} ->
          IO.write(content)
          send_mqtt_message(%{"llm" => content})
        end)
      end,
      on_message_processed: fn _chain, %Message{} = data ->
        # the message was assembled and is processed
        IO.puts("")
        IO.puts("")
        send_llm_full(data.content |> Enum.reduce(" ", fn msg, acc -> acc <> msg.content end))
        IO.inspect(data.content, label: "COMPLETED MESSAGE")
      end
    }
    try do
      notify_llm_begin()
      {:ok, updated_chain} =
        LLMChain.new!(%{
          llm: ChatOpenAI.new!(
            %{
              endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
              api_key: System.fetch_env!("DASHSCOPE_API_KEY"),
              model: "qwen-plus",
              stream: true
            })
        })
        |> LLMChain.add_message(Message.new_user!(text))
        |> LLMChain.add_callback(handler)
        |> LLMChain.run()
      IO.puts(ChainResult.to_string!(updated_chain))
    after
      notify_llm_end()
    end
  end

  defp send_mqtt_message(json_term) do
    payload = Jason.encode!(json_term)
    EmqxRpc.send_mqtt_message("asr_client", "$ai-proxy/voice_client", payload, %{qos: 0})
  end

end
