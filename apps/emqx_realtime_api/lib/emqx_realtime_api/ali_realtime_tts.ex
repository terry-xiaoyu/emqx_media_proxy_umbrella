defmodule EmqxRealtimeApi.AliRealtimeTTS do
  require Logger
  alias EmqxRealtimeApi.{AliRealtimeWs}

  @behaviour AliRealtimeWs

  @type provider_opts() :: AliRealtimeWs.provider_opts()

  @spec start_link(parent :: pid(), provider_opts()) :: GenServer.on_start()
  def start_link(parent, opts) do
    AliRealtimeWs.start_link(__MODULE__, :text, Map.merge(opts, %{parent: parent}))
  end

  def tts(pid, text) do
    GenServer.cast(pid, {:input, text})
  end

  def finish(pid) do
    :ok = AliRealtimeWs.send_finish_task_cmd(pid)
  end

  # Callbacks
  @impl AliRealtimeWs
  def rws_init(state) do
    Map.merge(state, %{
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
  def rws_handle_info(_info, state) do
    state
  end

  @impl AliRealtimeWs
  def rws_handle_outputs(state, _) do
    state
  end

  @impl AliRealtimeWs
  def rws_handle_bin_outputs(state, []) do
    state
  end

  def rws_handle_bin_outputs(%{opts: opts} = state, bin_outputs) do
    for bin <- bin_outputs, do: send(opts.parent, {:tts_response, bin})
    state
  end

  @impl AliRealtimeWs
  def rws_make_run_task_cmd(task_id, opts) do
    ## GStreamer commands to test TTS output:
    ## [MP3]:
    ##  gst-launch-1.0 udpsrc port=5003 ! mpegaudioparse ! mpg123audiodec ! audioconvert ! audioresample ! autoaudiosink
    ## [PCM]:
    ##  gst-launch-1.0 udpsrc port=5003 caps='audio/x-raw,format=S16LE,channels=1,rate=22050' ! autoaudiosink
    ## [Receive MP3 and convert to Opus]:
    ##  gst-launch-1.0 -v udpsrc port=5003 caps="application/x-rtp,media=audio,clock-rate=48000,encoding-name=OPUS" ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! osxaudiosink
    IO.puts("Making run task command for TTS with task_id: #{task_id}, opts: #{inspect(opts)}")
    Jason.encode!(
      %{
        "header" => %{
          "action" => "run-task",
          "task_id" => task_id,
          "streaming" => "duplex"
        },
        "payload" => %{
          "task_group" => "audio",
          "task" => "tts",
          "function" => "SpeechSynthesizer",
          "model" => Map.get(opts, :model, "cosyvoice-v2"),
          "parameters" => %{
            "text_type" => "PlainText",
            "voice" => "longxiaochun_v2",
            "format" => Map.get(opts, :format, "mp3"),
            "sample_rate" => Map.get(opts, :sample_rate, 8_000),
            "volume" => 50,
            "rate" => 1,
            "pitch" => 1
          },
          "input" => %{}
        }
      })
  end

  @impl AliRealtimeWs
  def rws_make_continue_task_cmd(text, task_id, _opts) do
    Jason.encode!(%{
      "header" => %{
        "action" => "continue-task",
        "task_id" => task_id,
        "streaming" => "duplex"
      },
      "payload" => %{
        "input" => %{
          "text" => normalize(text)
        }
      }
    })
  end

  @impl AliRealtimeWs
  def rws_make_finish_task_cmd(task_id, _state) do
    Jason.encode!(%{
      "header" => %{
        "action" => "finish-task",
        "task_id" => task_id,
        "streaming" => "duplex"
      },
      "payload" => %{
        "input" => %{}
      }
    })
  end

  defp normalize(text) do
    ## remove line breaks and emojis
    text
    |> String.replace(~r/[\r\n\x{1F000}-\x{1F6FF}]/u, " ")
    |> String.trim()
  end

end
