#!/usr/bin/env bash
# Deploy NIM (Llama 3.1 8B Instruct) to an Amazon SageMaker real-time endpoint.
#   1. Create the ECR repository
#   2. Build the SageMaker-wrapped NIM image and push it to ECR
#   3. Create the SageMaker model, endpoint and GPU autoscaling policy
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
IMAGE_TAG="${IMAGE_TAG:-latest}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"

export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/3  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim

REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"
REGION="$(echo "${REGISTRY}" | cut -d. -f4)"

echo "=== 2/3  Building SageMaker NIM image and pushing to ECR ==="
echo "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin

docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/docker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 3/3  Creating SageMaker model, endpoint and autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Logs:     aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling:  aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query 'ProductionVariants[0].CurrentInstanceCount'"
