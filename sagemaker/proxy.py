"""
Minimal SageMaker hosting shim for NVIDIA NIM (stdlib only).

  GET  /ping         -> NIM GET  /v1/health/ready
  POST /invocations  -> NIM POST /v1/chat/completions  (body has "messages")
                        NIM POST /v1/completions       (otherwise)

Responses are streamed through chunk-by-chunk, so both InvokeEndpoint and
InvokeEndpointWithResponseStream ("stream": true) work.
"""
import http.client
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NIM_HOST = "127.0.0.1"
NIM_PORT = int(os.environ.get("NIM_SERVER_PORT", "8000"))
LISTEN_PORT = int(os.environ.get("SAGEMAKER_BIND_PORT", "8080"))
TIMEOUT = float(os.environ.get("NIM_PROXY_TIMEOUT", "600"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep /ping out of the logs
        if not self.path.startswith("/ping"):
            super().log_message(fmt, *args)

    def _forward(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection(NIM_HOST, NIM_PORT, timeout=TIMEOUT)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            resp = conn.getresponse()
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
        except (ConnectionError, OSError, http.client.HTTPException) as e:
            msg = json.dumps({"error": f"NIM backend unavailable: {e}"}).encode()
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
        finally:
            conn.close()

    def do_GET(self):
        if self.path.startswith("/ping"):
            self._forward("GET", "/v1/health/ready")
        else:
            self.send_error(404)

    def do_POST(self):
        if not self.path.startswith("/invocations"):
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            payload = json.loads(body or b"{}")
        except json.JSONDecodeError:
            self.send_error(400, "Request body must be JSON")
            return
        target = "/v1/chat/completions" if "messages" in payload else "/v1/completions"
        self._forward("POST", target, body, {"Content-Type": "application/json"})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
