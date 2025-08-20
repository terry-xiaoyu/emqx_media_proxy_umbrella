defmodule EmqxMediaProxyWeb.WebRTCController do
  use EmqxMediaProxyWeb, :controller
  alias EmqxMediaProxyWeb.WebrtcPipeline

  def home(conn, _params) do
    unique_id = UUID.uuid4()
    #DynamicSupervisor.start_child(EmqxMediaProxyWeb.DynSup, {WebrtcPipeline, %{unique_id: unique_id}})
    send(WebrtcPipeline, {:start_pipeline, unique_id})
    render(conn, :home, layout: false, signaling_id: unique_id)
  end
end
