import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class ParallelHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        assert self.headers.get("Authorization") == "Bearer test-only-key"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/polish":
            self.server.polish_started.set()
            if body["transcript"] == "polish-first":
                if not self.server.decision_started.wait(2):
                    self.reply({"error": "decision was not started concurrently"}, 500)
                    return
            else:
                self.server.release_polish.wait(5)
            self.reply({"text": "polished text"})
        elif self.path in ("/systemone", "/decisions"):
            self.server.decision_started.set()
            if not self.server.polish_started.wait(2):
                self.reply({"error": "polish was not started concurrently"}, 500)
                return
            state = body.get("state") or json.loads(body["input"])
            if state["transcript"] == "polish-first":
                self.server.release_decision.wait(5)
            probability = 0.9 if state["transcript"] == "accept" else 0.62
            answers = {"needs_polish": {"type": "noul", "noul": probability}}
            if self.path == "/decisions":
                answers = [{"name": "needs_polish", "type": "predicate", "probability": probability}]
            self.reply({"model": "custom", "answers": answers})
        else:
            self.reply({}, 404)

    def do_GET(self):
        if self.path == "/release":
            self.server.release_polish.set()
            self.reply({})
        elif self.path == "/release-decision":
            self.server.release_decision.set()
            self.reply({})
        elif self.path == "/state":
            self.reply({"decision_released": self.server.release_decision.is_set()})
        else:
            self.reply({}, 404)

    def reply(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), ParallelHandler)
server.polish_started = threading.Event()
server.release_polish = threading.Event()
server.decision_started = threading.Event()
server.release_decision = threading.Event()
print(server.server_port, flush=True)
server.serve_forever()
