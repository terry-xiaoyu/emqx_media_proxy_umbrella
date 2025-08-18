defmodule EmqxMediaProxyWeb.WebRTCController do
  use EmqxMediaProxyWeb, :controller

  def home(conn, _params) do
    render(conn, :home, layout: false)
  end
end
