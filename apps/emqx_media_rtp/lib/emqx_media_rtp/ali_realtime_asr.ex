defmodule EmqxMediaRtp.AliRealtimeAsr do
  use GenServer
  require Logger
  alias EmqxMediaRtp.RtpAgentHandler

  @reconnect_delay 5000

  @type asr_provider_opts() :: %{
    optional(:ws_endpoint) => String.t(),
    optional(:api_key) => String.t(),
    optional(:model) => String.t()
  }

  @spec start_link(asr_provider_opts()) :: GenServer.on_start()
  def start_link(opts) do
    api_key = Map.get(opts, :api_key, System.get_env("DASHSCOPE_API_KEY"))
    model = Map.get(opts, :model, "paraformer-realtime-v2")
    ep = Map.get(opts, :ws_endpoint, "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
    GenServer.start_link(__MODULE__, %{api_key: api_key, model: model, parsed_uri: URI.parse(ep)})
  end

  def recognize(pid, audio_frame) do
    GenServer.call(pid, {:recognize, audio_frame}, :infinity)
  end

  # Callbacks
  @impl true
  def init(%{parsed_uri: parsed_uri, api_key: api_key} = opts) do
    connect_ws = fn(state) -> connect_ws(parsed_uri, api_key, state) end
    state = %{
      bin_buf: <<>>,
      msg_buf: [],
      asr_results_buf: [],
      ws_data_buf: <<>>,
      audio_frame_buf: <<>>,
      opts: Map.delete(opts, :api_key),
      task_status: :idle,
      task_id: nil,
      reconn_ref: nil,
      delay_llm_tref: nil,
      connect_ws: connect_ws
    }
    case connect_ws.(state) do
      {:ok, state1} ->
        {:ok, state1}
      error ->
        {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_continue(:run_task, state) do
    {:ok, state} = run_task(state)
    {_, _, state} = do_recognize(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:recognize, audio_frame}, _from, %{task_status: :connected, task_id: nil, audio_frame_buf: audio_frame_buf} = state) do
    {:ok, state} = run_task(state)
    do_recognize(%{state | audio_frame_buf: <<audio_frame_buf::binary, audio_frame::binary>>})
  end

  def handle_call({:recognize, audio_frame}, _from, %{task_status: :started, audio_frame_buf: audio_frame_buf} = state) do
    do_recognize(%{state | audio_frame_buf: <<audio_frame_buf::binary, audio_frame::binary>>})
  end

  def handle_call({:recognize, audio_frame}, _from, %{task_status: status, audio_frame_buf: audio_frame_buf} = state) do
    Logger.warning("ASR task is not ready, current status: #{status}, buffering audio frame")
    {:reply, :ok, %{state | audio_frame_buf: <<audio_frame_buf::binary, audio_frame::binary>>}}
  end

  defp do_recognize(%{ws: ws, conn: conn, ws_ref: ref, audio_frame_buf: audio_frame_buf} = state) do
    case audio_frame_buf do
      <<>> ->
        {:reply, :ok, state}
      audio_frame ->
        {:ok, ws, data} = Mint.WebSocket.encode(ws, {:binary, audio_frame})
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn} ->
            #Logger.debug("Sent audio frame to ASR service")
            {:reply, :ok, %{state | conn: conn, ws: ws, audio_frame_buf: <<>>}}
          {:error, _, reason} ->
            Logger.error("Failed to send audio frame: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast(:start, state) do
    # Logic to start the ASR service
    {:noreply, state}
  end

  @impl true
  def handle_info(:request_llm, %{asr_results_buf: []} = state) do
    {:noreply, %{state | delay_llm_tref: nil}}
  end

  def handle_info(:request_llm, %{asr_results_buf: results} = state) do
    RtpAgentHandler.request_llm(Enum.join(results, " "))
    {:noreply, %{state | delay_llm_tref: nil, asr_results_buf: []}}
  end

  @impl true
  def handle_info(:reconnect, %{connect_ws: connect_ws} = state) do
    Logger.info("Reconnecting to ASR service...")
    case connect_ws.(state) do
      {:ok, state1} ->
        {:noreply, state1}
      error ->
        {:stop, error, state}
    end
  end

  @impl true
  def handle_info({closed, _}, state) when closed == :ssl_closed or closed == :tcp_closed do
    Logger.warning("Connection closed")
    state = schedule_reconnect(state)
    {:noreply, %{state | task_status: :idle, task_id: nil, conn: nil, ws: nil}}
  end

  @impl true
  def handle_info(message, %{conn: conn, ws_ref: ref, asr_results_buf: asr_results_buf} = state) do
    with {:ok, conn, [{:data, ^ref, data}]} <- Mint.WebSocket.stream(conn, message),
         {:ok, ws, frames} <- decode_ws_data(state.ws_data_buf <> data, state.ws) do
      state1 = handle_ws_frames(frames, state)
      case handle_service_response(%{state1 | conn: conn, ws: ws}) do
        {results, [], new_state} ->
          RtpAgentHandler.handle_asr_results(Enum.reverse(results))
          new_state = maybe_request_llm(%{new_state | asr_results_buf: asr_results_buf ++ results})
          {:noreply, %{new_state | msg_buf: [], ws_data_buf: <<>>}}
        {results, errs, new_state} when is_list(errs) ->
          RtpAgentHandler.handle_asr_results(Enum.reverse(results))
          Logger.error("ASR errors: #{inspect(errs)}")
          {:stop, {:shutdown, errs}, %{new_state | msg_buf: [], ws_data_buf: <<>>}}
      end
    else
      {:ok, conn, [{:status, ^ref, status}, {:headers, ^ref, resp_headers}, {:done, ^ref}]} ->
        IO.puts("WebSocket upgrade response received with status #{status}")
        {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, resp_headers)
        case state.audio_frame_buf do
          <<>> ->
            {:noreply, %{state | conn: conn, ws: ws, task_status: :connected}}
          _ ->
            {:noreply, %{state | conn: conn, ws: ws, task_status: :connected}, {:continue, :run_task}}
        end
      :unknown ->
        handle_common_info(message, state)
      err ->
        Logger.error("Error processing message: #{inspect(err)}")
        {:stop, {:shutdown, err}}
    end
  end

  def handle_common_info({socket_tag, _socket, data}, %{ws_data_buf: ws_data_buf} = state)
    when socket_tag == :tcp or socket_tag == :ssl do
      {:noreply, %{state | ws_data_buf: ws_data_buf <> data}}
  end

  def handle_common_info(message, state) do
    Logger.warning("Unexpected info: #{inspect(message)}")
    {:noreply, state}
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

  defp decode_ws_data(data, ws) do
    Mint.WebSocket.decode(ws, data)
  end

  defp handle_service_response(%{msg_buf: msgs} = state) do
    Enum.reduce(msgs, {[], [], state}, fn txt, {results, errs, state_acc} ->
      case do_handle_service_response(txt, state_acc) do
        {:ok, new_state} ->
          {results, errs, new_state}
        {:asr_result, text, new_state} ->
          {[text | results], errs, new_state}
        {:error, reason, new_state} ->
          Logger.error("ASR service error: #{inspect(reason)}")
          {results, [reason | errs], %{new_state | reconn_ref: nil}}
      end
    end)
  end

  defp do_handle_service_response("", state) do
    {:ok, state}
  end

  defp do_handle_service_response(txt, %{task_id: task_id} = state) do
    case Jason.decode(txt) do
      {:ok, %{"header" => %{"event" => "task-started", "task_id" => ^task_id}}} ->
        Logger.info("ASR task started with ID: #{task_id}")
        {:ok, %{state | task_status: :started}}
      {:ok, %{"header" => %{"event" => "task-finished", "task_id" => ^task_id}}} ->
        Logger.warning("ASR task finished with ID: #{task_id}")
        {:ok, %{state | task_status: :connected}}
      {:ok, %{"header" => %{"event" => "task-failed", "task_id" => ^task_id, "error_code" => "ResponseTimeout", "error_message" => error_message}}} ->
        Logger.info("ASR task timed out with ID: #{task_id}, error: #{inspect(error_message)}")
        {:ok, %{state| task_status: :connected, task_id: nil}}
      {:ok, %{"header" => %{"event" => "task-failed", "task_id" => ^task_id} = header}} ->
        error_code = Map.get(header, "error_code", nil)
        error_message = Map.get(header, "error_message", nil)
        Logger.error("ASR task failed with error code #{error_code}: #{error_message}")
        {:error, :asr_task_failed, %{state| task_status: :connected, task_id: nil}}
      {:ok, %{"header" => %{"event" => "result-generated"}} = cmd} ->
        if payload = cmd["payload"] do
          text = payload["output"]["sentence"]["text"]
          Logger.info("ASR result generated: #{text}")
          {:asr_result, text, state}
        else
          Logger.warning("ASR result generated but no payload found")
          {:ok, state}
        end
      {:ok, invalid_cmd} ->
        Logger.error("Received invalid ASR command: #{inspect(invalid_cmd)}")
        {:ok, state}
      {:error, reason} ->
        Logger.error("Failed to decode ASR response: #{inspect(reason)}, response: #{txt}")
        {:error, reason, state}
    end
  end

  defp handle_ws_frames(frames, state) do
    Enum.reduce(frames, state, fn
      {:text, msg}, %{msg_buf: msg_buf} = state_acc ->
        %{state_acc | msg_buf: msg_buf ++ [msg]}

      {:binary, binary}, %{bin_buf: bin_buf} = state_acc ->
        IO.puts("Received binary frame of size: #{byte_size(binary)}")
        %{state_acc | bin_buf: <<bin_buf::binary, binary::binary>>}

      {:ping, _}, acc ->
        acc

      {:pong, _}, acc ->
        acc

      {:close, code, reason}, state_acc ->
        Logger.warning("WebSocket closed with code #{code} and reason: #{inspect(reason)}")
        schedule_reconnect(state_acc)

      other, acc ->
        Logger.error("Received unknown frame type, ignoring: #{inspect(other)}")
        acc
    end)
  end

  defp connect_ws(parsed_uri, api_key, state) do
    with  {:ok, conn} <- Mint.HTTP.connect(http_scheme(parsed_uri.scheme), parsed_uri.host, parsed_uri.port, [protocols: [:http1]]),
          IO.puts("Connected to ASR service at #{parsed_uri.host}:#{parsed_uri.port}"),
          {:ok, conn, ref} <- Mint.WebSocket.upgrade(:wss, conn, parsed_uri.path, ws_headers(api_key)) do
        {:ok, Map.merge(state, %{conn: conn, ws: nil, ws_ref: ref, task_id: nil, task_status: :upgrading})}
      else
        error ->
          Logger.error("Failed to connect to ASR service: #{inspect(error)}")
          error
    end
  end

  defp run_task(%{conn: conn, ws: ws, ws_ref: ref, opts: opts} = state) do
    # Start the ASR task
    task_id = UUID.uuid4()
    run_task_cmd = make_run_task_cmd(task_id, opts)
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, {:text, Jason.encode!(run_task_cmd)}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      IO.puts("ASR task started with ID: #{task_id}")
      {:ok, %{state | conn: conn, ws: ws, task_id: task_id}}
    end
  end

  defp schedule_reconnect(%{reconn_ref: nil} = state) do
    %{state | reconn_ref: Process.send_after(self(), :reconnect, @reconnect_delay)}
  end

  defp schedule_reconnect(%{reconn_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | reconn_ref: Process.send_after(self(), :reconnect, @reconnect_delay)}
  end

  defp http_scheme("ws"), do: :http
  defp http_scheme("wss"), do: :https

  defp ws_headers(api_key) do
    [
      {"Authorization", "bearer #{api_key}"},
      {"X-DashScope-DataInspection", "enable"}
    ]
  end

  defp make_run_task_cmd(task_id, opts) do
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

end
