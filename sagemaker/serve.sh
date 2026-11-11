#!/usr/bin/env bash
# SageMaker runs `docker run <image> serve`; args are ignored here.
set -euo pipefail

if [[ -z "${NGC_API_KEY:-}" && -n "${NGC_API_KEY_SECRET_ID:-}" ]]; then
  NGC_API_KEY="$(python3 -I /opt/sm-adapter/get_secret.py "${NGC_API_KEY_SECRET_ID}")"
  export NGC_API_KEY
fi

: "${NIM_START_CMD:?NIM_START_CMD not set (build the image with scripts/deploy.sh)}"

# Start NIM in the background; exit the container if either process dies so
# SageMaker replaces the instance.
# shellcheck disable=SC2086 # NIM_START_CMD is intentionally word-split
${NIM_START_CMD} &
nim_pid=$!

caddy run --config /opt/sm-adapter/Caddyfile --adapter caddyfile &
caddy_pid=$!

trap 'kill -TERM "${nim_pid}" "${caddy_pid}" 2>/dev/null || true' TERM INT
wait -n "${nim_pid}" "${caddy_pid}"
exit_code=$?
kill -TERM "${nim_pid}" "${caddy_pid}" 2>/dev/null || true
exit "${exit_code}"
