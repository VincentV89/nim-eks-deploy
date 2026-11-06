#!/usr/bin/env bash
# Start NIM on :8000 and the SageMaker adapter proxy on :8080.
# Exit (so SageMaker replaces the instance) if either process dies.
set -euo pipefail

NIM_START_CMD="${NIM_START_CMD:-/opt/nim/start_server.sh}"

"${NIM_START_CMD}" &
nim_pid=$!

caddy run --config /opt/sagemaker/Caddyfile --adapter caddyfile &
caddy_pid=$!

trap 'kill -TERM "$nim_pid" "$caddy_pid" 2>/dev/null || true' TERM INT

status=0
wait -n "$nim_pid" "$caddy_pid" || status=$?
kill -TERM "$nim_pid" "$caddy_pid" 2>/dev/null || true
exit "$status"
