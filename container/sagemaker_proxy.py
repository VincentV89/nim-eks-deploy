"""
Minimal SageMaker <-> NIM bridge (stdlib only).

  GET  /ping         -> GET  /v1/health/ready      (200 once the model is loaded)
  POST /invocations  -> POST /v1/chat/completions  (OpenAI-compatible JSON body)

Streaming responses (`"stream": true`) are forwarded chunk-by-chunk, which
works with SageMaker's InvokeEndpointWithResponseStream API.
"""
import http.client
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NIM_HOST = "127.0.0.1"
NIM_PORT = int(os.environ.get("NIM_SERVER_PORT", "8000"))
LISTEN_PORT = int(os.environ.get("SAGEMAKER_PORT", "8080"))
INVOKE_PATH = os.environ.get("NIM_INVOKE_PATH", "/v1/chat/completions")
TIMEOUT = 600  # seconds; SageMaker caps real-time invocations at 60s anyway


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep /ping noise out of CloudWatch
        if not self.path.startswith("/ping"):
            super().log_message(fmt, *args)

    def _forward(self, method, path, body=None):
        conn = http.client.HTTPConnection(NIM_HOST, NIM_PORT, timeout=TIMEOUT)
        try:
            headers = {"Content-Type": "application/json"} if body is not None else {}
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
        except OSError:
            conn.close()
            self._reply(503, b'{"error":"NIM not ready"}')
            return

        try:
            self.send_response(resp.status)
            self.send_header("Content-Type", resp.getheader("Content-Type", "application/json"))
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        finally:
            conn.close()

    def _reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/ping"):
            self._forward("GET", "/v1/health/ready")
        else:
            self._reply(404, b'{"error":"not found"}')

    def do_POST(self):
        if not self.path.startswith("/invocations"):
            self._reply(404, b'{"error":"not found"}')
            return
        length = int(self.headers.get("Content-Length", 0))
        self._forward("POST", INVOKE_PATH, self.rfile.read(length))


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
