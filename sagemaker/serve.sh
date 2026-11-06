#!/usr/bin/env bash
# SageMaker entrypoint: start NIM on :8000, then the SageMaker proxy on :8080.
set -euo pipefail

: "${NIM_START_CMD:?NIM_START_CMD must be set at image build time}"
export NIM_SERVER_PORT="${NIM_SERVER_PORT:-8000}"

# shellcheck disable=SC2086  # NIM_START_CMD is intentionally word-split
${NIM_START_CMD} &
NIM_PID=$!

PROXY_PYTHON="$(command -v python3 || command -v python)"
"${PROXY_PYTHON}" /opt/sagemaker/proxy.py &
PROXY_PID=$!

trap 'kill -TERM "${NIM_PID}" "${PROXY_PID}" 2>/dev/null || true' TERM INT

# Exit (and let SageMaker replace the instance) if either process dies.
wait -n "${NIM_PID}" "${PROXY_PID}"
STATUS=$?
kill -TERM "${NIM_PID}" "${PROXY_PID}" 2>/dev/null || true
exit "${STATUS}"
