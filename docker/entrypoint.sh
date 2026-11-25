#!/usr/bin/env bash
# SageMaker entrypoint: start NIM on :8000 and the Caddy shim on :8080.
# SageMaker invokes the container as `docker run <image> serve`; the argument
# is ignored here.
set -euo pipefail

caddy run --config /opt/sagemaker/Caddyfile --adapter caddyfile &
CADDY_PID=$!

/opt/nvidia/nvidia_entrypoint.sh /opt/nim/start_server.sh &
NIM_PID=$!

# If either process exits, stop the other so SageMaker replaces the instance.
trap 'kill "${CADDY_PID}" "${NIM_PID}" 2>/dev/null || true' TERM INT
wait -n "${CADDY_PID}" "${NIM_PID}"
EXIT_CODE=$?
kill "${CADDY_PID}" "${NIM_PID}" 2>/dev/null || true
exit "${EXIT_CODE}"
