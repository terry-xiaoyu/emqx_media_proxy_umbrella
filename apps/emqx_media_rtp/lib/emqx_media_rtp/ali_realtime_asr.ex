defmodule EmqxMediaRtp.AliRealtimeAsr do
  require Logger
  alias EmqxMediaRtp.{AliRealtimeWs, RtpAgentHandler}

  @behaviour AliRealtimeWs

  @type provider_opts() :: AliRealtimeWs.provider_opts()

  @spec start_link(provider_opts()) :: GenServer.on_start()
  def start_link(opts) do
    AliRealtimeWs.start_link(__MODULE__, :binary, opts)
  end

  def recognize(pid, audio_frame) do
    GenServer.call(pid, {:input, audio_frame}, :infinity)
  end

  # Callbacks
  @impl AliRealtimeWs
  def init(state) do
    Map.merge(state, %{
      asr_results_buf: [],
      audio_frame_buf: <<>>,
      delay_llm_tref: nil
    })
  end

  @impl AliRealtimeWs
  def handle_continue(_request, state) do
    state
  end

  @impl AliRealtimeWs
  def handle_call(_request, state) do
    state
  end

  @impl AliRealtimeWs
  def handle_cast(_request, state) do
    state
  end

  @impl AliRealtimeWs
  def handle_info(:request_llm, %{asr_results_buf: []} = state) do
    %{state | delay_llm_tref: nil}
  end

  def handle_info(:request_llm, %{asr_results_buf: results} = state) do
    RtpAgentHandler.request_llm(Enum.join(results, " "))
    %{state | delay_llm_tref: nil, asr_results_buf: []}
  end

  def handle_info(_info, state) do
    state
  end

  @impl AliRealtimeWs
  def handle_outputs([], state) do
    state
  end

  def handle_outputs(outputs, %{asr_results_buf: asr_results_buf} = state) do
    text_outputs = for output <- outputs, is_map(output), do: output["sentence"]["text"]
    RtpAgentHandler.handle_asr_results(text_outputs)
    maybe_request_llm(%{state | asr_results_buf: asr_results_buf ++ text_outputs})
  end

  @impl AliRealtimeWs
  def make_run_task_cmd(task_id, opts) do
    %{
      "header" => %{
        "action" => "run-task",
        "task_id" => task_id,
        "streaming" => "duplex"
      },
      "payload" => %{
        "task_group" => "audio",
        "task" => "asr",
        "function" => "recognition",
        "model" => opts.model,
        "parameters" => %{
          "format" => "wav",
          "sample_rate" => 48000,
          "disfluency_removal_enabled" => false
        },
        "resources" => [],
        "input" => %{}
      }
    }
  end

  @llm_delay 6000
  defp maybe_request_llm(%{delay_llm_tref: nil} = state) do
    tref = Process.send_after(self(), :request_llm, @llm_delay)
    %{state | delay_llm_tref: tref}
  end

  defp maybe_request_llm(%{delay_llm_tref: tref, asr_results_buf: results} = state) do
    _ = Process.cancel_timer(tref)
    if results == [] do
      %{state | delay_llm_tref: nil}
    else
      if is_end_mark(List.last(results)) do
        RtpAgentHandler.request_llm(Enum.join(results, " "))
        %{state | delay_llm_tref: nil, asr_results_buf: []}
      else
        tref = Process.send_after(self(), :request_llm, @llm_delay)
        %{state | delay_llm_tref: tref}
      end
    end
  end

  defp is_end_mark(text) do
    is_end_sentence(
      text
      |> String.trim()
      |> String.trim_trailing("?")
      |> String.trim_trailing("？")
      |> String.trim_trailing(".")
      |> String.trim_trailing("。")
      |> String.trim_trailing("!")
      |> String.trim_trailing("！")
      |> String.downcase()
    )
  end

  defp is_end_sentence(text) do
    String.ends_with?(text, "over")
      or String.ends_with?(text, "that's all")
      or String.ends_with?(text, "that's it")
      or String.ends_with?(text, "i'm done")
      or String.ends_with?(text, "over to you")
      or String.ends_with?(text, "your turn")
      or String.ends_with?(text, "结束了")
      or String.ends_with?(text, "我说完了")
      or String.ends_with?(text, "你说吧")
      or String.ends_with?(text, "完毕")
      or String.ends_with?(text, "结束")
      or String.ends_with?(text, "完结")
      or String.ends_with?(text, "完了")
  end

end
