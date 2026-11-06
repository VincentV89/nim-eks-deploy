#!/usr/bin/env bash
# SageMaker entrypoint: start the NIM server plus the Caddy route shim and
# exit (so SageMaker replaces the instance) as soon as either one dies.
set -uo pipefail

# Command that launches the NIM OpenAI-compatible server inside the base image.
# Override with the NIM_START_CMD environment variable if your NIM image uses
# a different start script.
NIM_START_CMD="${NIM_START_CMD:-/opt/nim/start_server.sh}"
export NIM_SERVER_PORT="${NIM_SERVER_PORT:-8000}"

if [[ -z "${NGC_API_KEY:-}" ]]; then
  echo "WARNING: NGC_API_KEY is not set; NIM will not be able to download model weights." >&2
fi

echo "Starting NIM: ${NIM_START_CMD} (port ${NIM_SERVER_PORT})"
${NIM_START_CMD} &
NIM_PID=$!

echo "Starting SageMaker route shim on :8080"
caddy run --config "${CADDYFILE:-/opt/sagemaker/Caddyfile}" --adapter caddyfile &
CADDY_PID=$!

shutdown() {
  kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true
  wait
}
trap shutdown TERM INT

wait -n "${NIM_PID}" "${CADDY_PID}"
EXIT_CODE=$?
echo "A server process exited (code ${EXIT_CODE}); shutting down." >&2
shutdown
exit "${EXIT_CODE}"
