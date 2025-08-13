defmodule EmqxMediaRtp.AliRealtimeWs do
  use GenServer
  require Logger

  @type state() :: map()
  @type output() :: map()
  @type provider_opts() :: %{
    optional(:ws_endpoint) => String.t(),
    optional(:api_key) => String.t(),
    optional(:model) => String.t(),
    atom() => any()
  }
  @type input_type() :: :text | :binary
  @type task_id() :: String.t()

  @callback rws_init(state()) :: state()
  @callback rws_handle_continue(any(), state()) :: state()
  @callback rws_handle_call(any(), state()) :: state()
  @callback rws_handle_cast(any(), state()) :: state()
  @callback rws_handle_info(any(), state()) :: state()
  @callback rws_handle_outputs(state(), list(output())) :: state()
  @callback rws_handle_bin_outputs(state(), binary()) :: state()
  @callback rws_make_run_task_cmd(task_id(), provider_opts()) :: binary()
  @callback rws_make_continue_task_cmd(input :: any(), task_id(), provider_opts()) :: binary()
  @callback rws_make_finish_task_cmd(task_id(), state()) :: binary()

  @reconnect_delay 5000

  @spec start_link(module(), input_type(), provider_opts()) :: GenServer.on_start()
  def start_link(mod, input_type, opts) do
    api_key = Map.get(opts, :api_key, System.get_env("DASHSCOPE_API_KEY"))
    ep = Map.get(opts, :ws_endpoint, "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
    GenServer.start_link(__MODULE__, {
      %{
        mod: mod,
        input_type: input_type,
        api_key: api_key,
        parsed_uri: URI.parse(ep)
      },
      Map.delete(opts, :api_key)
    })
  end

  def send_finish_task_cmd(pid) do
    GenServer.call(pid, :send_finish_task_cmd, :infinity)
  end

  # Callbacks
  @impl true
  def init({%{mod: mod, input_type: input_type, parsed_uri: parsed_uri, api_key: api_key}, opts}) do
    connect_ws = fn(state) -> connect_ws(parsed_uri, api_key, state) end
    state = %{
      mod: mod,
      input_type: input_type,
      input_buf: [],
      output_bin_buf: <<>>,
      output_text_buf: [],
      ws_data_buf: <<>>,
      opts: opts,
      task_status: :idle,
      task_id: nil,
      reconn_ref: nil,
      connect_ws: connect_ws
    }
    case connect_ws.(mod.rws_init(state)) do
      {:ok, state1} ->
        {:ok, state1}
      error ->
        {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_continue(:run_task, %{mod: mod} = state) do
    {:ok, state} = run_task(state)
    {:noreply, mod.rws_handle_continue(:run_task, state)}
  end

  def handle_continue(msg, %{mod: mod} = state) do
    {:noreply, mod.rws_handle_continue(msg, state)}
  end

  def run_task(%{conn: conn, ws: ws, ws_ref: ref, opts: opts, mod: mod} = state) do
    # Start the Task
    task_id = UUID.uuid4()
    run_task_cmd = mod.rws_make_run_task_cmd(task_id, opts)
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, {:text, run_task_cmd}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      Logger.info("#{mod} - Sent task-run command with ID: #{task_id}")
      {:ok, %{state | conn: conn, ws: ws, task_id: task_id, task_status: :started}}
    end
  end

  @impl true
  def handle_call(:send_finish_task_cmd, _from, %{task_status: :started, task_id: task_id, mod: mod, input_buf: input_buf, ws_ref: ref, input_type: input_type} = state) do
    finish_cmd = mod.rws_make_finish_task_cmd(task_id, state)
    with {:ok, conn, ws} <- do_handle_input(input_buf, state.conn, state.ws, ref, input_type),
         {:ok, conn, ws} <- do_handle_input([finish_cmd], conn, ws, ref, input_type) do
      {:reply, :ok, %{state | conn: conn, ws: ws, task_status: :connected, input_buf: []}}
    end
  end

  def handle_call(:send_finish_task_cmd, _from, %{task_status: _} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:input, input_frag} = request, %{task_status: :connected} = state) do
    {:ok, state} = run_task(state)
    handle_input(state |> cb_handle_call(request) |> buffer_input(input_frag))
  end

  def handle_cast({:input, input_frag} = request, %{task_status: :started} = state) do
    handle_input(state |> cb_handle_call(request) |> buffer_input(input_frag))
  end

  def handle_cast({:input, input_frag} = request, %{task_status: status} = state) do
    Logger.warning("#{state.mod} - Task is not ready, current status: #{status}, buffering input")
    {:noreply, state |> cb_handle_call(request) |> buffer_input(input_frag)}
  end

  def handle_cast(request, %{mod: mod} = state) do
    {:noreply, mod.rws_handle_cast(request, state)}
  end

  @impl true
  def handle_info(:reconnect, %{connect_ws: connect_ws} = state) do
    Logger.info("#{state.mod} - Reconnecting to service...")
    case connect_ws.(state) do
      {:ok, state1} ->
        {:noreply, state1}
      error ->
        {:stop, error, state}
    end
  end

  def handle_info({closed, _}, state) when closed == :ssl_closed or closed == :tcp_closed do
    Logger.warning("#{state.mod} - Connection closed")
    state = schedule_reconnect(state)
    {:noreply, %{state | task_status: :idle, task_id: nil, conn: nil, ws: nil}}
  end

  def handle_info(
      {socket_tag, _socket, socket_data} = message,
      %{conn: conn, ws_ref: ref, mod: mod} = state
    ) when socket_tag == :tcp or socket_tag == :ssl do
    with {:ok, conn, [{:data, ^ref, data}]} <- Mint.WebSocket.stream(conn, message),
         {:ok, ws, frames} <- Mint.WebSocket.decode(state.ws, state.ws_data_buf <> data) do
      {outputs, errs, state} =
        state
        |> handle_ws_frames(frames)
        |> Map.merge(%{conn: conn, ws: ws})
        |> handle_service_response()
      state =
        state
        |> mod.rws_handle_outputs(Enum.reverse(outputs))
        |> mod.rws_handle_bin_outputs(state.output_bin_buf)
      if errs == [] do
          {:noreply, %{state | output_text_buf: [], output_bin_buf: <<>>, ws_data_buf: <<>>}}
      else
          Logger.error("#{mod} - Service errors: #{inspect(errs)}")
          {:stop, {:shutdown, errs}, %{state | output_text_buf: [], output_bin_buf: <<>>, ws_data_buf: <<>>}}
      end
    else
      {:ok, conn, [{:status, ^ref, status}, {:headers, ^ref, resp_headers}, {:done, ^ref}]} ->
        IO.puts("WebSocket upgrade response received with status #{status}")
        {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, resp_headers)
        case state.input_buf do
          [] ->
            {:noreply, %{state | conn: conn, ws: ws, task_status: :connected}}
          _ ->
            {:noreply, %{state | conn: conn, ws: ws, task_status: :connected}, {:continue, :run_task}}
        end
      :unknown ->
        {:noreply, %{state | ws_data_buf: state.ws_data_buf <> socket_data}}
      err ->
        Logger.error("#{state.mod} - Error processing message: #{inspect(err)}")
        {:stop, {:shutdown, err}}
    end
  end

  def handle_info(info, %{mod: mod} = state) do
    {:noreply, mod.rws_handle_info(info, state)}
  end

  defp buffer_input(%{input_buf: input_buf, mod: mod, task_id: task_id, opts: opts} = state, input_frag) do
    %{state | input_buf: input_buf ++ [mod.rws_make_continue_task_cmd(input_frag, task_id, opts)]}
  end

  defp handle_input(%{conn: conn, ws: ws, ws_ref: ref, input_buf: input_buf, input_type: input_type} = state) do
    case do_handle_input(input_buf, conn, ws, ref, input_type) do
      {:ok, conn, ws} ->
        {:noreply, %{state | conn: conn, ws: ws, input_buf: []}}
      {:error, _, reason} ->
        Logger.error("#{state.mod} - Failed to send input: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, state}
    end
  end

  defp do_handle_input([], conn, ws, _ref, _) do
    {:ok, conn, ws}
  end

  defp do_handle_input([input | input_buf], conn, ws, ref, input_type) do
    {:ok, ws, data} = Mint.WebSocket.encode(ws, {input_type, input})
    case Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, conn} ->
        #IO.puts("Sent input: #{inspect(input)}")
        do_handle_input(input_buf, conn, ws, ref, input_type)
      {:error, _, _} = err ->
        err
    end
  end

  defp handle_service_response(%{output_text_buf: texts} = state) do
    Enum.reduce(texts, {[], [], state}, fn txt, {outputs, errs, state_acc} ->
      case do_handle_service_response(txt, state_acc) do
        {:ok, new_state} ->
          {outputs, errs, new_state}
        {:output, output, new_state} ->
          {[output | outputs], errs, new_state}
        {:error, reason, new_state} ->
          Logger.error("#{state.mod} - Service error: #{inspect(reason)}")
          {outputs, [reason | errs], %{new_state | reconn_ref: nil}}
      end
    end)
  end

  defp do_handle_service_response("", state) do
    {:ok, state}
  end

  defp do_handle_service_response(txt, %{task_id: task_id, mod: mod} = state) do
    case Jason.decode(txt) do
      {:ok, %{"header" => %{"event" => "task-started", "task_id" => ^task_id}}} ->
        Logger.info("#{mod} - Task started with ID: #{task_id}")
        {:ok, %{state | task_status: :started}}
      {:ok, %{"header" => %{"event" => "task-finished", "task_id" => ^task_id}}} ->
        Logger.warning("#{mod} - Task finished with ID: #{task_id}")
        {:ok, %{state | task_status: :connected}}
      {:ok, %{"header" => %{"event" => "task-failed", "task_id" => ^task_id, "error_code" => "ResponseTimeout", "error_message" => error_message}}} ->
        Logger.info("#{mod} - Task timed out with ID: #{task_id}, error: #{inspect(error_message)}")
        {:ok, %{state| task_status: :connected, task_id: nil}}
      {:ok, %{"header" => %{"event" => "task-failed", "task_id" => ^task_id} = header}} ->
        error_code = Map.get(header, "error_code", nil)
        error_message = Map.get(header, "error_message", nil)
        Logger.error("#{mod} - Task failed with error code #{error_code}: #{error_message}")
        {:error, :task_failed, %{state| task_status: :connected, task_id: nil}}
      {:ok, %{"header" => %{"event" => "result-generated"}} = cmd} ->
        if payload = cmd["payload"] do
          output = payload["output"]
          #Logger.info("Result generated: #{inspect(output)}")
          {:output, output, state}
        else
          Logger.warning("#{mod} - Result generated but no payload found")
          {:ok, state}
        end
      {:ok, invalid_cmd} ->
        Logger.error("#{mod} - Received invalid command: #{inspect(invalid_cmd)}")
        {:ok, state}
      {:error, reason} ->
        Logger.error("#{mod} - Failed to decode response: #{inspect(reason)}, response: #{txt}")
        {:error, reason, state}
    end
  end

  defp handle_ws_frames(state, frames) do
    Enum.reduce(frames, state, fn
      {:text, text}, %{output_text_buf: output_text_buf} = state_acc ->
        %{state_acc | output_text_buf: output_text_buf ++ [text]}

      {:binary, binary}, %{output_bin_buf: output_bin_buf} = state_acc ->
        #IO.puts("Received binary frame of size: #{byte_size(binary)}")
        %{state_acc | output_bin_buf: <<output_bin_buf::binary, binary::binary>>}

      {:ping, _}, acc ->
        acc

      {:pong, _}, acc ->
        acc

      {:close, code, reason}, state_acc ->
        Logger.warning("#{state.mod} - WebSocket closed with code #{code} and reason: #{inspect(reason)}")
        schedule_reconnect(state_acc)

      other, acc ->
        Logger.error("#{state.mod} - Received unknown frame type, ignoring: #{inspect(other)}")
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
          Logger.error("#{state.mod} - Failed to connect to service: #{inspect(error)}")
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

  defp cb_handle_call(%{mod: mod} = state, request) do
    mod.rws_handle_call(request, state)
  end

end
