#!/usr/bin/env bash
# Send one chat completion to the SageMaker NIM endpoint.
# Usage: ./scripts/invoke.sh <endpoint-name> [prompt]
set -euo pipefail

ENDPOINT="${1:?Usage: ./scripts/invoke.sh <endpoint-name> [prompt]}"
PROMPT="${2:-Hello}"
REGION="${AWS_REGION:-us-east-1}"
OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT

BODY="$(python3 -c 'import json,sys; print(json.dumps({
  "model": "meta/llama-3.1-8b-instruct",
  "messages": [{"role": "user", "content": sys.argv[1]}],
  "max_tokens": 50,
}))' "${PROMPT}")"

aws sagemaker-runtime invoke-endpoint \
  --region "${REGION}" \
  --endpoint-name "${ENDPOINT}" \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body "${BODY}" \
  "${OUT}" >/dev/null

cat "${OUT}"
echo
