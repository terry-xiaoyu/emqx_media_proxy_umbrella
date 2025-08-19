defmodule EmqxRealtimeApi.AliRealtimeASR do
  require Logger
  alias EmqxRealtimeApi.{AliRealtimeWs, AiAgentHandler}

  @behaviour AliRealtimeWs

  @type provider_opts() :: AliRealtimeWs.provider_opts()

  @spec start_link(parent :: pid(), provider_opts()) :: GenServer.on_start()
  def start_link(parent, opts) do
    AliRealtimeWs.start_link(__MODULE__, :binary, Map.merge(opts, %{parent: parent}))
  end

  def recognize(pid, audio_frame) do
    GenServer.cast(pid, {:input, audio_frame})
  end

  # Callbacks
  @impl AliRealtimeWs
  def rws_init(state) do
    Map.merge(state, %{
      asr_results_buf: [],
      asr_results_last_ts: 0,
      audio_frame_buf: <<>>,
      delay_llm_tref: nil
    })
  end

  @impl AliRealtimeWs
  def rws_handle_continue(_request, state) do
    state
  end

  @impl AliRealtimeWs
  def rws_handle_call(_request, state) do
    state
  end

  @impl AliRealtimeWs
  def rws_handle_cast(_request, state) do
    state
  end

  @impl AliRealtimeWs
  def rws_handle_info(:request_llm, %{asr_results_buf: []} = state) do
    %{state | delay_llm_tref: nil}
  end

  def rws_handle_info(:request_llm, %{asr_results_buf: results} = state) do
    AiAgentHandler.request_llm(state.opts.parent, Enum.join(results, " "))
    %{state | delay_llm_tref: nil, asr_results_buf: []}
  end

  def rws_handle_info(info, state) do
    Logger.warning("Unhandled info message: #{inspect(info)}")
    state
  end

  @impl AliRealtimeWs
  def rws_handle_outputs(state, []) do
    state
  end

  def rws_handle_outputs(%{asr_results_buf: asr_results_buf, asr_results_last_ts: asr_results_last_ts} = state, outputs) do
    AiAgentHandler.handle_asr_results(outputs)
    {asr_buf, last_ts} = merge_asr_results(asr_results_buf, asr_results_last_ts, outputs)
    maybe_request_llm(%{state | asr_results_buf: asr_buf, asr_results_last_ts: last_ts})
  end

  @impl AliRealtimeWs
  def rws_handle_bin_outputs(state, _) do
    state
  end

  @impl AliRealtimeWs
  def rws_make_run_task_cmd(task_id, opts) do
    Jason.encode!(
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
          "model" => Map.get(opts, :model, "paraformer-realtime-v2"),
          "parameters" => %{
            "format" => "wav",
            "sample_rate" => Map.get(opts, :sample_rate, 48_000),
            "disfluency_removal_enabled" => false
          },
          "resources" => [],
          "input" => %{}
        }
      })
  end

  @impl AliRealtimeWs
  def rws_make_finish_task_cmd(_task_id, _state) do
    <<>>
  end

  @impl AliRealtimeWs
  def rws_make_continue_task_cmd(bin, _task_id, _opts) do
    bin
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
        AiAgentHandler.request_llm(state.opts.parent, Enum.join(results, " "))
        %{state | delay_llm_tref: nil, asr_results_buf: []}
      else
        tref = Process.send_after(self(), :request_llm, @llm_delay)
        %{state | delay_llm_tref: tref}
      end
    end
  end

  def merge_asr_results(asr_results_buf, asr_results_last_ts, outputs) do
    Enum.reduce(outputs, {asr_results_buf, asr_results_last_ts},
      fn output, {acc, last_ts} ->
        sentence = output["sentence"]
        begin_ts = sentence["begin_time"]
        text = sentence["text"]
        # drop the last text in the buffer if the begin_time is same
        if begin_ts == last_ts do
          {replace_last(acc, text), begin_ts}
        else
          {acc ++ [text], begin_ts}
        end
      end)
  end

  defp replace_last([], new_text), do: [new_text]
  defp replace_last(list, new_text) do
    [_last | remlist] = Enum.reverse(list)
    Enum.reverse(remlist) ++ [new_text]
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
