#!/usr/bin/env bash
# Build the SageMaker-wrapped NIM image, push it to ECR, and deploy the
# SageMaker endpoint with Terraform.
# Usage: NGC_API_KEY=nvapi-... ./scripts/deploy.sh
#    or: ./scripts/deploy.sh <NGC_API_KEY>
set -euo pipefail

NGC_KEY="${1:-${NGC_API_KEY:-}}"
: "${NGC_KEY:?Usage: ./scripts/deploy.sh <NGC_API_KEY>  (or set NGC_API_KEY)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
REGION="${AWS_REGION:-us-east-1}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3}"
IMAGE_TAG="${IMAGE_TAG:-${NIM_IMAGE##*:}}"

export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_region="${REGION}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/4  Pulling NIM image from NGC ==="
# --password-stdin keeps the key out of the process list / shell history
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker pull --platform linux/amd64 "${NIM_IMAGE}"

echo "=== 3/4  Building SageMaker image and pushing to ECR ==="
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint (takes ~10-20 min on first boot) ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Status:  aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Logs:    aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Test:    python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 1 --duration 5"
