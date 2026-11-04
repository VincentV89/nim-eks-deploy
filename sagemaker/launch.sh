#!/usr/bin/env bash
# Container entrypoint for NIM on SageMaker.
#  1. Fetch the NGC API key from Secrets Manager (never baked into the image or
#     the SageMaker model definition).
#  2. Start NIM with its original entrypoint/cmd on :8000.
#  3. Start Caddy on :8080 to translate the SageMaker contract.
# If either process exits, the container exits so SageMaker replaces it.
set -euo pipefail

if [[ -z "${NGC_API_KEY:-}" && -n "${NGC_API_KEY_SECRET_ID:-}" ]]; then
  echo "[launch] Fetching NGC API key from Secrets Manager"
  NGC_API_KEY="$(aws secretsmanager get-secret-value \
    --secret-id "${NGC_API_KEY_SECRET_ID}" \
    --query SecretString --output text)"
  export NGC_API_KEY
fi

if [[ -z "${NGC_API_KEY:-}" ]]; then
  echo "[launch] ERROR: NGC_API_KEY is not set (set NGC_API_KEY_SECRET_ID)" >&2
  exit 1
fi

if [[ -z "${NIM_START_CMD:-}" ]]; then
  echo "[launch] ERROR: NIM_START_CMD is empty; rebuild the image with scripts/deploy.sh" >&2
  exit 1
fi

echo "[launch] Starting NIM: ${NIM_START_CMD}"
# Intentional word splitting: NIM_START_CMD is "<entrypoint...> <cmd...>".
# shellcheck disable=SC2086
${NIM_START_CMD} &
NIM_PID=$!

echo "[launch] Starting Caddy on :8080"
caddy run --config /opt/sagemaker/Caddyfile --adapter caddyfile &
CADDY_PID=$!

trap 'kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true' TERM INT

# Exit as soon as either process dies.
set +e
wait -n "${NIM_PID}" "${CADDY_PID}"
STATUS=$?
echo "[launch] A child process exited with status ${STATUS}; shutting down" >&2
kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null
wait
exit "${STATUS}"
