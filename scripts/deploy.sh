#!/usr/bin/env bash
# Build the SageMaker-compatible NIM image, push it to ECR and deploy the
# SageMaker real-time endpoint with GPU-utilization autoscaling.
#
# Usage: NGC_API_KEY=<key> ./scripts/deploy.sh
#        ./scripts/deploy.sh <NGC_API_KEY>          (key ends up in shell history)
#
# Optional env:
#   NIM_IMAGE  base NIM image   (default nvcr.io/nim/meta/llama-3.1-8b-instruct:latest)
#   IMAGE_TAG  tag pushed to ECR (default: current git short SHA)
set -euo pipefail

NGC_KEY="${NGC_API_KEY:-${1:-}}"
if [[ -z "${NGC_KEY}" ]]; then
  echo "Usage: NGC_API_KEY=<key> $0   (or: $0 <NGC_API_KEY>)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo latest)}"

for bin in aws docker terraform; do
  command -v "${bin}" >/dev/null || { echo "ERROR: '${bin}' is required" >&2; exit 1; }
done

tf() { terraform -chdir="${TF_DIR}" "$@"; }

echo "=== 1/4  Creating ECR repository and NGC secret ==="
tf init -input=false
tf apply -input=false -auto-approve \
  -target=aws_ecr_repository.nim \
  -target=aws_secretsmanager_secret.ngc_api_key

REPO_URL="$(tf output -raw ecr_repository_url)"
SECRET_ARN="$(tf output -raw ngc_secret_arn)"
REGION="$(tf output -raw region 2>/dev/null || aws configure get region || echo us-east-1)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/4  Storing NGC API key in Secrets Manager ==="
# Pass the key via a temp file so it does not show up in the process list.
KEY_FILE="$(mktemp)"
trap 'rm -f "${KEY_FILE}"' EXIT
printf '%s' "${NGC_KEY}" > "${KEY_FILE}"
aws secretsmanager put-secret-value --region "${REGION}" \
  --secret-id "${SECRET_ARN}" \
  --secret-string "file://${KEY_FILE}" >/dev/null

echo "=== 3/4  Building and pushing SageMaker NIM image (${REPO_URL}:${IMAGE_TAG}) ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin

docker build --platform linux/amd64 \
  --build-arg "NIM_IMAGE=${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" -t "${REPO_URL}:latest" \
  "${ROOT}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"
docker push "${REPO_URL}:latest"

echo "=== 4/4  Deploying SageMaker endpoint (first boot can take 10-20 min) ==="
tf apply -input=false -auto-approve -var "image_tag=${IMAGE_TAG}"

echo ""
echo "Done! Endpoint: $(tf output -raw endpoint_name)"
echo "Test it:        $(tf output -raw invoke_example)"
echo "Load test:      python scripts/load_test.py $(tf output -raw endpoint_name) --region ${REGION}"
