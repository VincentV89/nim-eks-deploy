#!/usr/bin/env bash
# Container entrypoint for NIM on SageMaker.
# 1. Resolve NGC_API_KEY (from Secrets Manager if NGC_API_KEY_SECRET_ARN is set)
# 2. Start NIM on :8000
# 3. Start the Caddy shim on :8080 (SageMaker /ping + /invocations)
set -euo pipefail

if [[ -z "${NGC_API_KEY:-}" && -n "${NGC_API_KEY_SECRET_ARN:-}" ]]; then
  echo "[launch] Fetching NGC API key from Secrets Manager"
  NGC_API_KEY="$(python3 -c '
import os, boto3
print(boto3.client("secretsmanager").get_secret_value(
    SecretId=os.environ["NGC_API_KEY_SECRET_ARN"])["SecretString"].strip())
')"
  export NGC_API_KEY
fi

if [[ -z "${NGC_API_KEY:-}" ]]; then
  echo "[launch] ERROR: NGC_API_KEY or NGC_API_KEY_SECRET_ARN must be set" >&2
  exit 1
fi

export NIM_SERVER_PORT="${NIM_SERVER_PORT:-8000}"
NIM_CMD="${NIM_CMD:-/opt/nim/start_server.sh}"

echo "[launch] Starting NIM on :${NIM_SERVER_PORT}"
"${NIM_CMD}" &
nim_pid=$!

echo "[launch] Starting SageMaker shim on :8080"
caddy run --config /opt/sagemaker/Caddyfile --adapter caddyfile &
caddy_pid=$!

trap 'kill -TERM "${nim_pid}" "${caddy_pid}" 2>/dev/null || true' TERM INT

# If either process exits, stop the container so SageMaker replaces it.
status=0
wait -n "${nim_pid}" "${caddy_pid}" || status=$?
kill -TERM "${nim_pid}" "${caddy_pid}" 2>/dev/null || true
exit "${status}"
