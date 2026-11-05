#!/usr/bin/env bash
# Container entrypoint for SageMaker. SageMaker starts the container with the
# argument "serve"; it is ignored here. Requires bash >= 5.1 (wait -n <pids>).
set -euo pipefail

export NIM_SERVER_PORT="${NIM_SERVER_PORT:-8000}"
# Start command of the upstream NIM image (baked in at build time, overridable).
NIM_START_CMD="${NIM_START_CMD:-/opt/nvidia/nvidia_entrypoint.sh /opt/nim/start-server.sh}"

# Read the NGC key from Secrets Manager so it is never part of the SageMaker
# model definition (DescribeModel only shows the secret ARN).
if [[ -z "${NGC_API_KEY:-}" && -n "${NGC_SECRET_ARN:-}" ]]; then
  NGC_API_KEY="$(aws secretsmanager get-secret-value \
    --secret-id "${NGC_SECRET_ARN}" --query SecretString --output text)"
  export NGC_API_KEY
fi
[[ -n "${NGC_API_KEY:-}" ]] || { echo "NGC_API_KEY / NGC_SECRET_ARN not set" >&2; exit 1; }

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# shellcheck disable=SC2086
${NIM_START_CMD} &
NIM_PID=$!

trap 'kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true' TERM INT

# Exit (and let SageMaker restart the container) if either process dies.
# `|| status=$?` keeps set -e from skipping the cleanup below.
status=0
wait -n "${NIM_PID}" "${CADDY_PID}" || status=$?
kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true
wait || true
exit "${status}"
