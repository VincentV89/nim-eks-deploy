#!/usr/bin/env bash
# Deploy NIM to a GPU-backed Amazon SageMaker real-time endpoint.
# Usage: ./scripts/deploy.sh [NGC_API_KEY]     (or export NGC_API_KEY)
# Requires: aws, docker (with buildx), terraform
set -euo pipefail

NGC_KEY="${1:-${NGC_API_KEY:-}}"
: "${NGC_KEY:?Usage: ./scripts/deploy.sh <NGC_API_KEY>  (or export NGC_API_KEY)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
REGION="${AWS_REGION:-us-east-1}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-llama-3.1-8b-instruct}"

export TF_VAR_region="${REGION}"
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/3  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
ECR_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${ECR_URL%%/*}"

echo "=== 2/3  Building SageMaker-compatible NIM image and pushing to ECR ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker buildx build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${ECR_URL}:${IMAGE_TAG}" --push "${ROOT}/container"

echo "=== 3/3  Creating SageMaker model, endpoint and autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Logs:      aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling:   aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region ${REGION}"
