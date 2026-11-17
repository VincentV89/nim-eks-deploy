#!/usr/bin/env bash
# Start NIM (port 8000) and the SageMaker routing shim (port 8080).
set -euo pipefail

# Locate NIM's server start script (name varies across NIM releases);
# override with NIM_START_CMD if your image differs.
if [[ -z "${NIM_START_CMD:-}" ]]; then
  for c in /opt/nim/start_server.sh /opt/nim/start-server.sh; do
    [[ -x "$c" ]] && NIM_START_CMD="$c" && break
  done
fi
: "${NIM_START_CMD:?Could not find NIM start script; set NIM_START_CMD}"

if [[ -x /opt/nvidia/nvidia_entrypoint.sh ]]; then
  /opt/nvidia/nvidia_entrypoint.sh "$NIM_START_CMD" &
else
  "$NIM_START_CMD" &
fi
NIM_PID=$!

caddy run --config /opt/sagemaker/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# Exit (so SageMaker replaces the instance) if either process dies.
trap 'kill "$NIM_PID" "$CADDY_PID" 2>/dev/null || true' TERM INT
wait -n "$NIM_PID" "$CADDY_PID"
exit_code=$?
kill "$NIM_PID" "$CADDY_PID" 2>/dev/null || true
exit "$exit_code"
