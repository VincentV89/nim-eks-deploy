#!/usr/bin/env bash
# Entrypoint for the SageMaker NIM image: run NIM on :8000 and the
# SageMaker-contract proxy on :8080. Exit if either process dies so SageMaker
# replaces the instance.
set -euo pipefail

NIM_START_CMD="${NIM_START_CMD:-/opt/nvidia/nvidia_entrypoint.sh /opt/nim/start_server.sh}"

# shellcheck disable=SC2086  # intentional word splitting of the command string
${NIM_START_CMD} &
nim_pid=$!

caddy run --config /opt/sagemaker/Caddyfile --adapter caddyfile &
proxy_pid=$!

trap 'kill -TERM "${nim_pid}" "${proxy_pid}" 2>/dev/null || true' TERM INT

status=0
wait -n "${nim_pid}" "${proxy_pid}" || status=$?
kill -TERM "${nim_pid}" "${proxy_pid}" 2>/dev/null || true
exit "${status}"
