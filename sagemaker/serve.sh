#!/usr/bin/env bash
# Container entrypoint for SageMaker: start NIM on :8000 and Caddy on :8080.
# SageMaker invokes the container with the single argument "serve", which is
# accepted and ignored here.
set -euo pipefail

: "${NGC_API_KEY:?NGC_API_KEY must be set (passed via the SageMaker model environment)}"

# NIM's stock start script. Override with NIM_START_CMD if a future NIM
# release moves it.
NIM_START_CMD="${NIM_START_CMD:-/opt/nim/start_server.sh}"
if [[ ! -x "${NIM_START_CMD}" && -x /opt/nim/start-server.sh ]]; then
  NIM_START_CMD=/opt/nim/start-server.sh
fi

echo "[serve] starting NIM: ${NIM_START_CMD} (port ${NIM_SERVER_PORT:-8000})"
"${NIM_START_CMD}" &
nim_pid=$!

echo "[serve] starting Caddy on :8080"
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!

shutdown() {
  kill -TERM "${nim_pid}" "${caddy_pid}" 2>/dev/null || true
  wait || true
}
trap shutdown TERM INT

# If either process exits, stop the container so SageMaker replaces it.
set +e
wait -n "${nim_pid}" "${caddy_pid}"
status=$?
echo "[serve] a child process exited with status ${status}; shutting down"
shutdown
exit "${status}"
