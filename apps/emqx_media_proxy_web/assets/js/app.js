// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

import {channel} from "./channel_socket.js"
// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken}
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// for WebRTC compoments
const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' },] };
// we set the resolution manually in order to give simulcast enough bitrate to create 3 encodings
const mediaConstraints = {
  // video: {
  //   width: { ideal: 1280 },
  //   height: { ideal: 720 },
  //   facingMode: 'user'
  // },
  audio: {
      echoCancellation: true,
      noiseSuppression: true,
      sampleRate: 48000
  }
}

document.addEventListener('DOMContentLoaded', async () => {
  const videoPlayer = document.getElementById("videoPlayer");
  if (!videoPlayer) {
    console.error("Video player element not found");
    return;
  }
  const pc = new RTCPeerConnection(pcConfig);
  // expose pc for easier debugging and experiments
  window.pc = pc;
  pc.ontrack = event => videoPlayer.srcObject = event.streams[0];
  pc.onicecandidate = event => {
    if (event.candidate === null) return;

    console.log("Sent ICE candidate:", event.candidate);
    channel.push("signaling", { type: "ice", data: event.candidate });
  };

  const localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
  // pc.addTransceiver(localStream.getVideoTracks()[0], {
  //   direction: "sendrecv",
  //   streams: [localStream],
  //   sendEncodings: [
  //     { rid: "h", maxBitrate: 1200 * 1024},
  //     { rid: "m", scaleResolutionDownBy: 2, maxBitrate: 600 * 1024},
  //     { rid: "l", scaleResolutionDownBy: 4, maxBitrate: 300 * 1024 },
  //   ],
  // });
  // replace the call above with this to disable simulcast
  // pc.addTrack(localStream.getVideoTracks()[0]);
  //pc.addTrack(localStream.getAudioTracks()[0]);
  for (const track of localStream.getTracks()) {
    pc.addTrack(track, localStream);
  }

  channel.on("signaling", async payload => {
    console.log("Received signaling message:", payload);
    const {type, data} = payload;

    switch (type) {
      case "answer":
        console.log("Received SDP answer:", data);
        await pc.setRemoteDescription(data)
        break;
      case "ice":
        console.log("Received ICE candidate:", data);
        await pc.addIceCandidate(data);
    }
  });

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  console.log("Sent SDP offer:", offer)
  channel.push("signaling", {type: "offer", data: offer});
});
