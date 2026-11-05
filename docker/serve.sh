#!/usr/bin/env bash
# Entrypoint for NIM on SageMaker: start the 8080 adapter proxy, then NIM itself.
set -euo pipefail

caddy start --config /opt/sagemaker/Caddyfile --adapter caddyfile

# Hand off to the stock NIM entrypoint (same as the upstream image's ENTRYPOINT+CMD)
exec /opt/nvidia/nvidia_entrypoint.sh /opt/nim/start_server.sh
