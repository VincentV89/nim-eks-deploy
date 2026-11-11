#!/usr/bin/env bash
# Build the SageMaker NIM image, push it to ECR, and deploy the SageMaker endpoint.
# Usage: ./scripts/deploy.sh <NGC_API_KEY> [image-tag]
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY> [image-tag]}"
TAG="${2:-$(date +%Y%m%d%H%M%S)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_image_tag="${TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGION="$(echo "${REPO}" | cut -d. -f4)"
REGISTRY="${REPO%%/*}"

echo "=== 2/4  Logging in to nvcr.io and ECR ==="
echo "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin

echo "=== 3/4  Building and pushing SageMaker NIM image (${REPO}:${TAG}) ==="
docker build --platform linux/amd64 -t "${REPO}:${TAG}" "${ROOT}/sagemaker"
docker push "${REPO}:${TAG}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService (first boot builds the TensorRT engine)."
echo "Check status:  aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Logs:          aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
