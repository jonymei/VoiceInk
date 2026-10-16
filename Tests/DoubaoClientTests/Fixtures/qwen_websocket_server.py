import base64
import hashlib
import json
import struct
from http.server import BaseHTTPRequestHandler, HTTPServer


class QwenHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        assert self.path == "/api-ws/v1/inference"
        assert self.headers.get("Authorization") == "Bearer test-only-key"
        accept = base64.b64encode(hashlib.sha1(
            (self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
        ).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        opcode, body = self.read_frame()
        assert opcode == 1
        start = json.loads(body)
        assert start["header"]["action"] == "run-task"
        self.task_id = start["header"]["task_id"]
        assert start["payload"]["model"] == "qwen-audio-3.1-asr-flash-message"
        parameters = start["payload"]["parameters"]
        assert parameters["disfluency_removal_enabled"] is True
        assert parameters["intermediate_result_enabled"] is True
        assert parameters["format"] == "pcm" and parameters["sample_rate"] == 16000
        self.send_event("task-started")
        audio_bytes = 0
        while True:
            opcode, body = self.read_frame()
            if opcode == 2:
                audio_bytes += len(body)
                self.send_event("result-generated", {
                    "sentence_id": 1, "text": "partial draft", "sentence_end": False
                })
                continue
            assert opcode == 1
            finish = json.loads(body)
            assert finish["header"]["action"] == "finish-task"
            assert finish["header"]["task_id"] == self.task_id
            assert audio_bytes == 32000
            self.send_event("result-generated", {
                "sentence_id": 1, "text": "Clean ASR result.", "sentence_end": True
            })
            self.send_event("result-generated", {
                "sentence_id": 1, "text": "Clean ASR result.", "sentence_end": True
            })
            self.send_event("task-finished")
            break
        self.close_connection = True

    def read_frame(self):
        first, second = self.read_exact(2)
        length = second & 127
        if length == 126:
            length = struct.unpack(">H", self.read_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self.read_exact(8))[0]
        assert length < 100000 and second & 128 and first & 128
        mask = self.read_exact(4)
        payload = self.read_exact(length)
        return first & 15, bytes(value ^ mask[i % 4] for i, value in enumerate(payload))

    def read_exact(self, count):
        data = self.rfile.read(count)
        if len(data) != count:
            raise EOFError("Incomplete frame")
        return data

    def send_event(self, event, sentence=None):
        payload = {} if sentence is None else {"output": {"sentence": sentence}}
        data = json.dumps({
            "header": {"task_id": self.task_id, "event": event}, "payload": payload
        }).encode()
        header = bytes([0x81, len(data)]) if len(data) < 126 else bytes([0x81, 126]) + struct.pack(">H", len(data))
        self.wfile.write(header + data)
        self.wfile.flush()


server = HTTPServer(("127.0.0.1", 0), QwenHandler)
server.timeout = 20
print(server.server_port, flush=True)
server.handle_request()
server.server_close()
