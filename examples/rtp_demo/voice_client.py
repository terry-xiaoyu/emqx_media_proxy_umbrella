import json
import subprocess
import sys
import signal
import os
from typing import Optional

import paho.mqtt.client as mqtt

# gst-launch-1.0 -v osxaudiosrc ! audio/x-raw,rate=48000,channels=1 ! opusenc ! rtpopuspay pt=120 ! udpsink host=127.0.0.1 port=6001

# gst-launch-1.0 udpsrc port=6001 caps="application/x-rtp,media=audio,clock-rate=48000,encoding-name=OPUS" ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! osxaudiosink

class VoiceClient:
    def __init__(self, mqtt_broker: str, mqtt_port: int = 1883):
        self.mqtt_broker = mqtt_broker
        self.mqtt_port = mqtt_port
        self.mqtt_clientid = "voice_client"
        self.topic = f"$ai-proxy/{self.mqtt_clientid}"
        self.mqtt_client = mqtt.Client(client_id=self.mqtt_clientid)
        self.gst_send_process: Optional[subprocess.Popen] = None
        self.gst_receive_process: Optional[subprocess.Popen] = None
        self.current_text = ""
        self.current_llm_text = ""
        self.is_llm_text_on_going = False
        self.text_buff = ""
        
        # Audio settings
        self.sample_rate = 48000
        self.channels = 1
        
        # Setup MQTT callbacks
        self.mqtt_client.on_connect = self._on_connect
        self.mqtt_client.on_message = self._on_message
        
    def _on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            print("Connected to MQTT broker")
            client.subscribe(self.topic)
        else:
            print(f"Failed to connect to MQTT broker: {rc}")
    
    def _on_message(self, client, userdata, msg):
        try:
            if msg.topic == self.topic:
                data = json.loads(msg.payload.decode())
                if 'port' in data:
                    # voice-invite message
                    port = data.get('port')
                    if port:
                        self._handle_voice_invite(port)
                elif 'text' in data:
                    # txt message
                    if self.is_llm_text_on_going:
                        # If LLM text is ongoing, append to buffer
                        self.text_buff += data.get('text', '')
                    else:
                        # If not, handle the text message immediately
                        self.text_buff += data.get('text', '')
                        self._print_text_message(self.text_buff)
                        self.text_buff = ""
                elif 'llm' in data:
                    # llm message
                    llm_text = data.get('llm')
                    if llm_text == '$llm_begin$':
                        if self.is_llm_text_on_going == False:
                            sys.stdout.write('\n')
                            self._print_llm_message("Thinking...")
                            self.is_llm_text_on_going = True
                    elif llm_text == '$llm_end$':
                        sys.stdout.write('\n')
                        self.is_llm_text_on_going = False
                        self._print_text_message(self.text_buff)
                        self.text_buff = ""
                    else:
                        self.is_llm_text_on_going = True
                        self._print_llm_message(llm_text)
                elif 'full_llm' in data:
                    # full_llm message
                    full_llm_text = data.get('full_llm', '')
                    self._print_llm_message(full_llm_text)

        except Exception as e:
            print(f"Error handling message: {e}")
    
    def _handle_voice_invite(self, port: int):
        print(f"received voice invite on port {port}")

        # Start GStreamer pipelines
        self._start_gstreamer_send_pipeline(port)
        self._start_gstreamer_receive_pipeline(port + 1)
    
    def _print_text_message(self, text: str):
        # remove the \n from the text
        text = "👦: " + text.strip().replace('\n', ' ')
        # Clear current line and print new text
        sys.stdout.write('\r' + ' ' * len(self.current_text) * 2)
        sys.stdout.write('\r' + text)
        sys.stdout.flush()
        self.current_text = text
    
    def _print_llm_message(self, llm_text: str):
        llm_text = "🤖: " + llm_text.strip().replace('\n', ' ')
        # Clear current line and print new text
        sys.stdout.write('\r' + ' ' * len(self.current_llm_text) * 2)
        sys.stdout.write('\r' + llm_text)
        sys.stdout.flush()
        self.current_llm_text = llm_text

    def _start_gstreamer_send_pipeline(self, port: int):
        """Start GStreamer pipeline for audio capture and RTP sending"""
        # GStreamer pipeline for audio capture: microphone -> opus encoder -> RTP sender
        gst_send_cmd = [
            'gst-launch-1.0',
            'osxaudiosrc',
            '!', f'audio/x-raw,rate={self.sample_rate},channels={self.channels}',
            '!', 'opusenc',
            '!', 'rtpopuspay', 'pt=120',
            '!', 'udpsink', f'host=127.0.0.1', f'port={port}'
        ]
        print(f"Starting GStreamer send pipeline on port {port} with command: {' '.join(gst_send_cmd)}")
        
        try:
            self.gst_send_process = subprocess.Popen(
                gst_send_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                preexec_fn=os.setsid
            )
            print(f"Started GStreamer send pipeline on port {port}")
        except Exception as e:
            print(f"Error starting GStreamer send pipeline: {e}")
    
    def _start_gstreamer_receive_pipeline(self, port: int):
        """Start GStreamer pipeline for RTP receiving and audio playback"""
        # GStreamer pipeline for audio playback: RTP receiver -> opus decoder -> speakers
        gst_receive_cmd = [
            'gst-launch-1.0',
            '-v',
            'udpsrc', f'port={port}',
            'caps=application/x-rtp,media=audio,clock-rate=48000,encoding-name=OPUS',
            '!', 'rtpopusdepay',
            '!', 'opusdec',
            '!', 'audioconvert',
            '!', 'audioresample',
            '!', 'osxaudiosink'
        ]
        
        try:
            self.gst_receive_process = subprocess.Popen(
                gst_receive_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                preexec_fn=os.setsid
            )
            print(f"Started GStreamer receive pipeline on port {port}")
        except Exception as e:
            print(f"Error starting GStreamer receive pipeline: {e}")
    
    def connect(self):
        print(f"Connecting to MQTT broker at {self.mqtt_broker}:{self.mqtt_port}")
        self.mqtt_client.connect(self.mqtt_broker, self.mqtt_port, 60)
        self.mqtt_client.loop_start()
    
    def disconnect(self):
        print("Disconnecting...")
        
        # Stop MQTT
        self.mqtt_client.loop_stop()
        self.mqtt_client.disconnect()
        
        # Terminate GStreamer processes
        if self.gst_send_process:
            try:
                os.killpg(os.getpgid(self.gst_send_process.pid), signal.SIGTERM)
                self.gst_send_process.wait(timeout=5)
            except (subprocess.TimeoutExpired, ProcessLookupError):
                try:
                    os.killpg(os.getpgid(self.gst_send_process.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self.gst_send_process = None
        
        if self.gst_receive_process:
            try:
                os.killpg(os.getpgid(self.gst_receive_process.pid), signal.SIGTERM)
                self.gst_receive_process.wait(timeout=5)
            except (subprocess.TimeoutExpired, ProcessLookupError):
                try:
                    os.killpg(os.getpgid(self.gst_receive_process.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self.gst_receive_process = None


def main():
    import argparse
    
    parser = argparse.ArgumentParser(description="Voice Client with MQTT and RTP")
    parser.add_argument("--mqtt-broker", default="127.0.0.1", help="MQTT broker address")
    parser.add_argument("--mqtt-port", type=int, default=1883, help="MQTT broker port")
    
    args = parser.parse_args()
    
    client = VoiceClient(args.mqtt_broker, args.mqtt_port)
    
    try:
        client.connect()
        print("Voice client started. Press Ctrl+C to exit.")
        
        # Keep the main thread alive
        while True:
            import time
            time.sleep(1)
            
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        client.disconnect()


if __name__ == "__main__":
    main()
