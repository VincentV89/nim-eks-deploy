#!/usr/bin/env bash
# Starts NIM (port 8000) and the Caddy SageMaker shim (port 8080).
# SageMaker passes `serve` as the first argument; it is intentionally ignored.
set -euo pipefail

# Default NIM LLM launch command. Override with NIM_START_CMD if a NIM image
# uses a different entrypoint.
NIM_START_CMD="${NIM_START_CMD:-/opt/nvidia/nvidia_entrypoint.sh /opt/nim/start_server.sh}"

mkdir -p "${XDG_CONFIG_HOME:-/tmp/caddy/config}" "${XDG_DATA_HOME:-/tmp/caddy/data}"

caddy run --config /opt/sagemaker-shim/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# shellcheck disable=SC2086 # word splitting of the command is intended
${NIM_START_CMD} &
NIM_PID=$!

shutdown() {
  kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true
  wait || true
}
trap shutdown SIGTERM SIGINT

# Exit as soon as either process dies so SageMaker replaces the instance.
set +e
wait -n "${NIM_PID}" "${CADDY_PID}"
STATUS=$?
shutdown
exit "${STATUS}"
