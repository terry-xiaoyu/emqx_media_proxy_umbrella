defmodule EmqxMediaRtp.AliRealtimeWs do
  use GenServer
  require Logger

  @type state() :: map()
  @type output() :: map()
  @type provider_opts() :: %{
    optional(:ws_endpoint) => String.t(),
    optional(:api_key) => String.t(),
    optional(:model) => String.t()
  }
  @type input_type() :: :text | :binary

  @callback init(state()) :: state()
  @callback handle_continue(any(), state()) :: state()
  @callback handle_call(any(), state()) :: state()
  @callback handle_cast(any(), state()) :: state()
  @callback handle_info(any(), state()) :: state()
  @callback handle_outputs(list(output()), state()) :: state()
  @callback make_run_task_cmd(String.t(), provider_opts()) :: map()

  @reconnect_delay 5000

  @spec start_link(module(), input_type(), provider_opts()) :: GenServer.on_start()
  def start_link(mod, input_type, opts) do
    api_key = Map.get(opts, :api_key, System.get_env("DASHSCOPE_API_KEY"))
    model = Map.get(opts, :model, "paraformer-realtime-v2")
    ep = Map.get(opts, :ws_endpoint, "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
    GenServer.start_link(__MODULE__, %{mod: mod, input_type: input_type, api_key: api_key, model: model, parsed_uri: URI.parse(ep)})
  end

  # Callbacks
  @impl true
  def init(%{mod: mod, input_type: input_type, parsed_uri: parsed_uri, api_key: api_key} = opts) do
    connect_ws = fn(state) -> connect_ws(parsed_uri, api_key, state) end
    state = %{
      mod: mod,
      input_type: input_type,
      input_buf: <<>>,
      output_bin_buf: <<>>,
      output_text_buf: [],
      ws_data_buf: <<>>,
      opts: Map.delete(opts, :api_key),
      task_status: :idle,
      task_id: nil,
      reconn_ref: nil,
      connect_ws: connect_ws
    }
    case connect_ws.(mod.init(state)) do
      {:ok, state1} ->
        {:ok, state1}
      error ->
        {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_continue(:run_task, %{mod: mod} = state) do
    {:ok, state} = run_task(state)
    {:noreply, mod.handle_continue(:run_task, state)}
  end

  def handle_continue(msg, %{mod: mod} = state) do
    {:noreply, mod.handle_continue(msg, state)}
  end

  def run_task(%{conn: conn, ws: ws, ws_ref: ref, opts: opts, mod: mod} = state) do
    # Start the Taks
    task_id = UUID.uuid4()
    run_task_cmd = mod.make_run_task_cmd(task_id, opts)
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, {:text, Jason.encode!(run_task_cmd)}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      IO.puts("Taks started with ID: #{task_id}")
      {:ok, %{state | conn: conn, ws: ws, task_id: task_id}}
    end
  end

  @impl true
  def handle_call({:input, input_frag} = request, _from, %{task_status: :connected, task_id: nil, input_buf: input_buf} = state) do
    {:ok, state} = run_task(state)
    handle_input(%{cb_handle_call(request, state) | input_buf: <<input_buf::binary, input_frag::binary>>})
  end

  def handle_call({:input, input_frag} = request, _from, %{task_status: :started, input_buf: input_buf} = state) do
    handle_input(%{cb_handle_call(request, state) | input_buf: <<input_buf::binary, input_frag::binary>>})
  end

  def handle_call({:input, input_frag} = request, _from, %{task_status: status, input_buf: input_buf} = state) do
    Logger.warning("Task is not ready, current status: #{status}, buffering input")
    {:reply, :ok, %{cb_handle_call(request, state) | input_buf: <<input_buf::binary, input_frag::binary>>}}
  end

  defp handle_input(%{ws: ws, conn: conn, ws_ref: ref, input_buf: input_buf} = state) do
    case input_buf do
      <<>> ->
        {:reply, :ok, state}
      input_buf ->
        {:ok, ws, data} = Mint.WebSocket.encode(ws, {state.input_type, input_buf})
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn} ->
            #Logger.debug("Sent input to service")
            {:reply, :ok, %{state | conn: conn, ws: ws, input_buf: <<>>}}
          {:error, _, reason} ->
            Logger.error("Failed to send input: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast(request, %{mod: mod} = state) do
    {:noreply, mod.handle_cast(request, state)}
  end

  @impl true
  def handle_info(:reconnect, %{connect_ws: connect_ws} = state) do
    Logger.info("Reconnecting to service...")
    case connect_ws.(state) do
      {:ok, state1} ->
        {:noreply, state1}
      error ->
        {:stop, error, state}
    end
  end

  def handle_info({closed, _}, state) when closed == :ssl_closed or closed == :tcp_closed do
    Logger.warning("Connection closed")
    state = schedule_reconnect(state)
    {:noreply, %{state | task_status: :idle, task_id: nil, conn: nil, ws: nil}}
  end

  def handle_info(
      {socket_tag, _socket, socket_data} = message,
      %{conn: conn, ws_ref: ref, mod: mod} = state
    ) when socket_tag == :tcp or socket_tag == :ssl do
    with {:ok, conn, [{:data, ^ref, data}]} <- Mint.WebSocket.stream(conn, message),
         {:ok, ws, frames} <- Mint.WebSocket.decode(state.ws, state.ws_data_buf <> data) do
      case state |> handle_ws_frames(frames) |> Map.merge(%{conn: conn, ws: ws}) |> handle_service_response() do
        {outputs, [], state} ->
          state = mod.handle_outputs(Enum.reverse(outputs), state)
          {:noreply, %{state | output_text_buf: [], ws_data_buf: <<>>}}
        {outputs, errs, state} when is_list(errs) ->
          state = mod.handle_outputs(Enum.reverse(outputs), state)
          Logger.error("Service errors: #{inspect(errs)}")
          {:stop, {:shutdown, errs}, %{state | output_text_buf: [], ws_data_buf: <<>>}}
      end
    else
      {:ok, conn, [{:status, ^ref, status}, {:headers, ^ref, resp_headers}, {:done, ^ref}]} ->
        IO.puts("WebSocket upgrade response received with status #{status}")
        {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, resp_headers)
        case state.input_buf do
          <<>> ->
            {:noreply, %{state | conn: conn, ws: ws, task_status: :connected}}
          _ ->
            {:noreply, %{state | conn: conn, ws: ws, task_status: :connected}, {:continue, :run_task}}
        end
      :unknown ->
        {:noreply, %{state | ws_data_buf: state.ws_data_buf <> socket_data}}
      err ->
        Logger.error("Error processing message: #{inspect(err)}")
        {:stop, {:shutdown, err}}
    end
  end

  def handle_info(info, %{mod: mod} = state) do
    {:noreply, mod.handle_info(info, state)}
  end

  defp handle_service_response(%{output_text_buf: texts} = state) do
    Enum.reduce(texts, {[], [], state}, fn txt, {outputs, errs, state_acc} ->
      case do_handle_service_response(txt, state_acc) do
        {:ok, new_state} ->
          {outputs, errs, new_state}
        {:output, output, new_state} ->
          {[output | outputs], errs, new_state}
        {:error, reason, new_state} ->
          Logger.error("Service error: #{inspect(reason)}")
          {outputs, [reason | errs], %{new_state | reconn_ref: nil}}
      end
    end)
  end

  defp do_handle_service_response("", state) do
    {:ok, state}
  end

  defp do_handle_service_response(txt, %{task_id: task_id} = state) do
    case Jason.decode(txt) do
      {:ok, %{"header" => %{"event" => "task-started", "task_id" => ^task_id}}} ->
        Logger.info("Task started with ID: #{task_id}")
        {:ok, %{state | task_status: :started}}
      {:ok, %{"header" => %{"event" => "task-finished", "task_id" => ^task_id}}} ->
        Logger.warning("Taks finished with ID: #{task_id}")
        {:ok, %{state | task_status: :connected}}
      {:ok, %{"header" => %{"event" => "task-failed", "task_id" => ^task_id, "error_code" => "ResponseTimeout", "error_message" => error_message}}} ->
        Logger.info("Taks timed out with ID: #{task_id}, error: #{inspect(error_message)}")
        {:ok, %{state| task_status: :connected, task_id: nil}}
      {:ok, %{"header" => %{"event" => "task-failed", "task_id" => ^task_id} = header}} ->
        error_code = Map.get(header, "error_code", nil)
        error_message = Map.get(header, "error_message", nil)
        Logger.error("Taks failed with error code #{error_code}: #{error_message}")
        {:error, :task_failed, %{state| task_status: :connected, task_id: nil}}
      {:ok, %{"header" => %{"event" => "result-generated"}} = cmd} ->
        if payload = cmd["payload"] do
          output = payload["output"]
          Logger.info("Result generated: #{inspect(output)}")
          {:output, output, state}
        else
          Logger.warning("Result generated but no payload found")
          {:ok, state}
        end
      {:ok, invalid_cmd} ->
        Logger.error("Received invalid command: #{inspect(invalid_cmd)}")
        {:ok, state}
      {:error, reason} ->
        Logger.error("Failed to decode response: #{inspect(reason)}, response: #{txt}")
        {:error, reason, state}
    end
  end

  defp handle_ws_frames(state, frames) do
    Enum.reduce(frames, state, fn
      {:text, text}, %{output_text_buf: output_text_buf} = state_acc ->
        %{state_acc | output_text_buf: output_text_buf ++ [text]}

      {:binary, binary}, %{output_bin_buf: output_bin_buf} = state_acc ->
        IO.puts("Received binary frame of size: #{byte_size(binary)}")
        %{state_acc | output_bin_buf: <<output_bin_buf::binary, binary::binary>>}

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
          IO.puts("Connected to service at #{parsed_uri.host}:#{parsed_uri.port}"),
          {:ok, conn, ref} <- Mint.WebSocket.upgrade(:wss, conn, parsed_uri.path, ws_headers(api_key)) do
        {:ok, Map.merge(state, %{conn: conn, ws: nil, ws_ref: ref, task_id: nil, task_status: :upgrading})}
      else
        error ->
          Logger.error("Failed to connect to service: #{inspect(error)}")
          error
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

  defp cb_handle_call(request, %{mod: mod} = state) do
    mod.handle_call(request, state)
  end

end
