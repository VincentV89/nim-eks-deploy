#!/usr/bin/env bash
# Container entrypoint for SageMaker hosting.
# SageMaker runs the container as `docker run <image> serve`; the argument is ignored.
set -euo pipefail

# Resolve the NGC API key (needed by NIM to download model weights at startup).
# Preferred: read it from Secrets Manager so the key never appears in the
# SageMaker model definition (DescribeModel shows environment variables).
if [[ -z "${NGC_API_KEY:-}" && -n "${NGC_API_KEY_SECRET_ID:-}" ]]; then
  NGC_API_KEY="$(python3 - <<'PY'
import os, boto3
region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
client = boto3.client("secretsmanager", region_name=region)
print(client.get_secret_value(SecretId=os.environ["NGC_API_KEY_SECRET_ID"])["SecretString"].strip())
PY
)"
  export NGC_API_KEY
fi

if [[ -z "${NGC_API_KEY:-}" ]]; then
  echo "ERROR: NGC_API_KEY is not set (set NGC_API_KEY or NGC_API_KEY_SECRET_ID)" >&2
  exit 1
fi

# Start the SageMaker -> NIM reverse proxy in the background.
caddy start --config /opt/sagemaker/Caddyfile --adapter caddyfile

# Hand PID 1 to the NIM server (OpenAI-compatible API on :8000).
exec "${NIM_START_CMD:-/opt/nim/start_server.sh}"
