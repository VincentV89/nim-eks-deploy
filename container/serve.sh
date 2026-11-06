#!/usr/bin/env bash
# Start NIM (port 8000) and the SageMaker shim (port 8080) side by side.
# If either process exits, the container exits so SageMaker replaces the instance.
set -euo pipefail

# Default NIM LLM entrypoint + start command; override if the base image differs.
NIM_ENTRYPOINT="${NIM_ENTRYPOINT:-/opt/nvidia/nvidia_entrypoint.sh}"
NIM_START_CMD="${NIM_START_CMD:-/opt/nim/start_server.sh}"
export NIM_SERVER_PORT="${NIM_SERVER_PORT:-8000}"

if [[ -x "${NIM_ENTRYPOINT}" ]]; then
  "${NIM_ENTRYPOINT}" "${NIM_START_CMD}" &
else
  "${NIM_START_CMD}" &
fi
NIM_PID=$!

caddy run --config /opt/sagemaker/Caddyfile --adapter caddyfile &
CADDY_PID=$!

trap 'kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true' TERM INT

wait -n "${NIM_PID}" "${CADDY_PID}"
STATUS=$?
kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true
exit "${STATUS}"
