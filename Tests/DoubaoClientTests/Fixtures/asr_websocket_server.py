import base64
import hashlib
import json
import struct
from http.server import BaseHTTPRequestHandler, HTTPServer


class SpeechHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if (
            self.headers.get("X-Api-Key") != "test-only-key"
            or self.headers.get("X-Api-Resource-Id") != "volc.seedasr.sauc.duration"
        ):
            self.send_error(403)
            return
        accept = base64.b64encode(
            hashlib.sha1(
                (self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest()
        ).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        configuration = self.read_frame()
        assert configuration[:4] == bytes([0x11, 0x10, 0x10, 0])
        body = json.loads(configuration[8:])
        assert body["audio"]["rate"] == 16000
        assert body["audio"]["format"] == "pcm"
        assert body["request"]["enable_nonstream"] is True
        self.send_result(None)
        audio_bytes = 0
        while True:
            packet = self.read_frame()
            assert packet[1] >> 4 == 2
            length = struct.unpack(">I", packet[4:8])[0]
            assert length == len(packet) - 8
            audio_bytes += length
            if packet[1] & 2:
                assert audio_bytes == 32000
                self.send_result("Local websocket end-to-end passed.", final=True)
                break
            if self.path.endswith("bigmodel_async"):
                self.send_result("Local websocket partial")
        self.close_connection = True

    def read_exact(self, size):
        data = self.rfile.read(size)
        if len(data) != size:
            raise EOFError("WebSocket closed before a complete frame")
        return data

    def read_frame(self):
        first, second = self.read_exact(2)
        assert first & 15 == 2
        length = second & 127
        if length == 126:
            length = struct.unpack(">H", self.read_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self.read_exact(8))[0]
        assert length < 100000
        assert second & 128
        mask = self.read_exact(4)
        payload = self.read_exact(length)
        return bytes(value ^ mask[index % 4] for index, value in enumerate(payload))

    def send_result(self, text, final=False):
        body = {"result": {"additions": {"log_id": "test-log"}}} if text is None else {"result": {"text": text}}
        payload = json.dumps(body).encode()
        if text is None:
            packet = bytes([0x11, 0x90, 0x10, 0]) + struct.pack(">I", len(payload)) + payload
        else:
            packet = bytes([0x11, 0x93 if final else 0x91, 0x10, 0])
            packet += struct.pack(">iI", -3 if final else 1, len(payload)) + payload
        header = bytes([0x82, len(packet)]) if len(packet) < 126 else bytes([0x82, 126]) + struct.pack(">H", len(packet))
        self.wfile.write(header + packet)
        self.wfile.flush()


server = HTTPServer(("127.0.0.1", 0), SpeechHandler)
server.timeout = 20
print(server.server_port, flush=True)
server.handle_request()
server.server_close()
