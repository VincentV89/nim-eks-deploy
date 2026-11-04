#!/usr/bin/env bash
# SageMaker entrypoint: start NIM on :8000 and the SageMaker shim on :8080.
set -euo pipefail

if [[ -z "${NGC_API_KEY:-}" && -n "${NGC_API_KEY_SECRET_ARN:-}" ]]; then
  NGC_API_KEY="$(python3 - <<'PY'
import os, boto3
sm = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION"))
print(sm.get_secret_value(SecretId=os.environ["NGC_API_KEY_SECRET_ARN"])["SecretString"], end="")
PY
)"
  export NGC_API_KEY
fi
: "${NGC_API_KEY:?NGC_API_KEY or NGC_API_KEY_SECRET_ARN must be set}"

export NIM_SERVER_PORT="${NIM_SERVER_PORT:-8000}"
# Command that starts the NIM server inside the base image (override if your
# NIM version uses a different path).
NIM_START_CMD="${NIM_START_CMD:-/opt/nim/start_server.sh}"

${NIM_START_CMD} &
NIM_PID=$!

python3 /opt/sagemaker/proxy.py &
PROXY_PID=$!

trap 'kill -TERM "${NIM_PID}" "${PROXY_PID}" 2>/dev/null || true' TERM INT
# Exit (so SageMaker replaces the instance) if either process dies.
wait -n "${NIM_PID}" "${PROXY_PID}"
EXIT_CODE=$?
kill -TERM "${NIM_PID}" "${PROXY_PID}" 2>/dev/null || true
exit "${EXIT_CODE}"
