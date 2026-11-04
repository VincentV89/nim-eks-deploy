#!/usr/bin/env bash
# Container entrypoint for SageMaker hosting.
# SageMaker starts the container as `docker run <image> serve`; the argument is ignored.
#
#  1. Fetch the NGC API key from Secrets Manager (NIM needs it to download weights).
#  2. Start the NIM server on port 8000 (SageMaker only routes traffic to :8080).
#  3. Start Caddy on :8080 to translate /ping and /invocations to NIM routes.
#  If either process exits, the container exits and SageMaker replaces the instance.
set -euo pipefail

if [[ -z "${NGC_API_KEY:-}" ]]; then
  NGC_API_KEY="$(PYTHONPATH=/opt/shim/lib python3 /opt/shim/get_secret.py)"
  export NGC_API_KEY
fi

# Default command of the NIM LLM image; override via the NIM_START_CMD env var if a
# future NIM release changes it (`docker inspect <nim-image>` shows Entrypoint + Cmd).
read -r -a nim_cmd <<< "${NIM_START_CMD:-/opt/nvidia/nvidia_entrypoint.sh /opt/nim/start_server.sh}"

echo "[launch] starting NIM: ${nim_cmd[*]}"
"${nim_cmd[@]}" &
nim_pid=$!

echo "[launch] starting Caddy on :8080"
# The proxy does not need the NGC key, so strip it from Caddy's environment.
env -u NGC_API_KEY caddy run --config /opt/shim/Caddyfile --adapter caddyfile &
caddy_pid=$!

trap 'kill -TERM "${nim_pid}" "${caddy_pid}" 2>/dev/null || true' TERM INT

set +e
wait -n "${nim_pid}" "${caddy_pid}"
status=$?
set -e
echo "[launch] a child process exited with status ${status}; shutting down"
kill -TERM "${nim_pid}" "${caddy_pid}" 2>/dev/null || true
wait || true
exit "${status}"
