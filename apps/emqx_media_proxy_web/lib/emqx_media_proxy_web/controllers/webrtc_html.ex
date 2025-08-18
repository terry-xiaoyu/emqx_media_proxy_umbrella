defmodule EmqxMediaProxyWeb.WebRTCHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use EmqxMediaProxyWeb, :html

  embed_templates "webrtc_html/*"
end
