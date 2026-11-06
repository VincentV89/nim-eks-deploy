#!/usr/bin/env bash
# Build the SageMaker-adapted NIM image, push it to ECR, and deploy the SageMaker endpoint.
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
# Requires: aws, docker, terraform. Run from the repository root.
set -euo pipefail

NGC_KEY="${1:-${NGC_API_KEY:-}}"
: "${NGC_KEY:?Usage: ./scripts/deploy.sh <NGC_API_KEY>  (or export NGC_API_KEY)}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"
REGION="$(echo "${REGISTRY}" | cut -d. -f4)"

echo "=== 2/4  Logging in to NGC and ECR ==="
echo "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin

echo "=== 3/4  Building and pushing SageMaker-adapted NIM image ==="
# SageMaker GPU instances are x86_64.
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService (first boot builds the TensorRT engine)."
echo "Status:  aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Logs:    aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
