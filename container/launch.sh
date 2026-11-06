#!/usr/bin/env bash
# SageMaker entrypoint: resolve the NGC key, start NIM on :8000 and the
# SageMaker routing proxy on :8080. Exits if either process dies so SageMaker
# replaces the instance.
set -euo pipefail

if [[ -z "${NGC_API_KEY:-}" && -n "${NGC_API_KEY_SECRET_ARN:-}" ]]; then
  echo "Fetching NGC API key from Secrets Manager"
  NGC_API_KEY="$(aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${NGC_API_KEY_SECRET_ARN}" \
    --query SecretString --output text)"
  export NGC_API_KEY
fi

: "${NGC_API_KEY:?NGC_API_KEY or NGC_API_KEY_SECRET_ARN must be set}"

export NIM_SERVER_PORT=8000

caddy run --config /opt/sagemaker/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# Default entrypoint + command of the upstream NIM LLM image
/opt/nvidia/nvidia_entrypoint.sh /opt/nim/start-server.sh &
NIM_PID=$!

trap 'kill -TERM "${CADDY_PID}" "${NIM_PID}" 2>/dev/null || true' TERM INT

status=0
wait -n "${CADDY_PID}" "${NIM_PID}" || status=$?
echo "A child process exited (status ${status}); shutting down" >&2
kill -TERM "${CADDY_PID}" "${NIM_PID}" 2>/dev/null || true
exit "${status}"
