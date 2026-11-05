#!/usr/bin/env bash
# Entrypoint for NIM on SageMaker: start the SageMaker->NIM proxy, then NIM.
set -euo pipefail

caddy start --config /opt/sagemaker/Caddyfile --adapter caddyfile

# Hand PID 1 to the stock NIM entrypoint so signals reach the inference server.
exec /opt/nvidia/nvidia_entrypoint.sh /opt/nim/start-server.sh "$@"
