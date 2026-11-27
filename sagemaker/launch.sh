#!/usr/bin/env bash
# Container entrypoint for NIM on SageMaker: resolve the NGC key, start NIM on
# :8000 and a Caddy shim on :8080 that maps SageMaker's /ping + /invocations.
set -euo pipefail

if [[ -z "${NGC_API_KEY:-}" && -n "${NGC_API_KEY_SECRET_ARN:-}" ]]; then
  echo "[launch] Fetching NGC API key from Secrets Manager"
  NGC_API_KEY="$(PYTHONPATH=/opt/sagemaker/py python3 /opt/sagemaker/fetch_secret.py "${NGC_API_KEY_SECRET_ARN}")"
  export NGC_API_KEY
fi
: "${NGC_API_KEY:?NGC_API_KEY or NGC_API_KEY_SECRET_ARN must be set}"

export NIM_SERVER_PORT=8000

# NIM's start script name differs across releases; allow an explicit override.
if [[ -z "${NIM_START_CMD:-}" ]]; then
  for candidate in /opt/nim/start_server.sh /opt/nim/start-server.sh; do
    if [[ -x "${candidate}" ]]; then NIM_START_CMD="${candidate}"; break; fi
  done
fi
: "${NIM_START_CMD:?Could not locate NIM start script; set NIM_START_CMD}"

ENTRY=()
[[ -x /opt/nvidia/nvidia_entrypoint.sh ]] && ENTRY=(/opt/nvidia/nvidia_entrypoint.sh)

echo "[launch] Starting NIM: ${ENTRY[*]} ${NIM_START_CMD}"
"${ENTRY[@]}" "${NIM_START_CMD}" &
NIM_PID=$!

echo "[launch] Starting Caddy shim on :8080"
caddy run --config /opt/sagemaker/Caddyfile --adapter caddyfile &
CADDY_PID=$!

trap 'kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true' TERM INT

# Exit (and let SageMaker replace the instance) if either process dies.
wait -n "${NIM_PID}" "${CADDY_PID}"
status=$?
kill -TERM "${NIM_PID}" "${CADDY_PID}" 2>/dev/null || true
exit "${status}"
