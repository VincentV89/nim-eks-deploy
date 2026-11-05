#!/usr/bin/env bash
# Container entrypoint for SageMaker. SageMaker starts the container with the
# argument "serve"; it is ignored here.
set -euo pipefail

export NIM_SERVER_PORT="${NIM_SERVER_PORT:-8000}"
# Start command of the upstream NIM image (override if a NIM release changes it).
NIM_START_CMD="${NIM_START_CMD:-/opt/nvidia/nvidia_entrypoint.sh /opt/nim/start-server.sh}"

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# shellcheck disable=SC2086
${NIM_START_CMD} &
NIM_PID=$!

trap 'kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true' TERM INT

# Exit (and let SageMaker restart the container) if either process dies.
wait -n "${NIM_PID}" "${CADDY_PID}"
status=$?
kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true
exit "${status}"
