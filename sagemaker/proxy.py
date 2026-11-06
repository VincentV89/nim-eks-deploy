"""
Minimal SageMaker <-> NIM proxy (Python stdlib only).

  GET  /ping         -> GET  http://127.0.0.1:8000/v1/health/ready
  POST /invocations  -> POST http://127.0.0.1:8000/v1/chat/completions
                        (or /v1/completions if the body has "prompt" but no "messages")

Clients may override the target route with the SageMaker CustomAttributes
header, e.g. CustomAttributes="route=/v1/embeddings". Only /v1/* routes are allowed.
Streaming responses (InvokeEndpointWithResponseStream + "stream": true) are
relayed chunk by chunk.
"""
import http.client
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NIM_HOST = "127.0.0.1"
NIM_PORT = int(os.environ.get("NIM_SERVER_PORT", "8000"))
LISTEN_PORT = int(os.environ.get("SAGEMAKER_BIND_TO_PORT", "8080"))
TIMEOUT = float(os.environ.get("NIM_PROXY_TIMEOUT", "600"))
HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "content-length", "server", "date"}


def pick_route(headers, body):
    attrs = headers.get("X-Amzn-SageMaker-Custom-Attributes", "")
    for part in attrs.split(","):
        key, _, value = part.strip().partition("=")
        if key == "route" and value.startswith("/v1/") and ".." not in value:
            return value
    try:
        payload = json.loads(body or b"{}")
    except ValueError:
        payload = {}
    if isinstance(payload, dict) and "prompt" in payload and "messages" not in payload:
        return "/v1/completions"
    return "/v1/chat/completions"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep /ping noise out of CloudWatch
        if not self.path.startswith("/ping"):
            super().log_message(fmt, *args)

    def _forward(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection(NIM_HOST, NIM_PORT, timeout=TIMEOUT)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            resp = conn.getresponse()
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP_BY_HOP:
                    self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        except OSError as exc:
            self._error(503, f"NIM backend unavailable: {exc}")
        finally:
            conn.close()

    def _error(self, status, message):
        data = json.dumps({"error": message}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/ping":
            self._forward("GET", "/v1/health/ready")
        else:
            self._error(404, "not found")

    def do_POST(self):
        if self.path != "/invocations":
            self._error(404, "not found")
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        self._forward(
            "POST",
            pick_route(self.headers, body),
            body=body,
            headers={"Content-Type": "application/json", "Accept": self.headers.get("Accept", "*/*")},
        )


if __name__ == "__main__":
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
