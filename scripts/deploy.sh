#!/usr/bin/env bash
# Build the SageMaker-compatible NIM image, push it to ECR and deploy the
# SageMaker real-time endpoint (with GPU autoscaling) via Terraform.
# Usage: ./scripts/deploy.sh <NGC_API_KEY> [IMAGE_TAG]
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY> [IMAGE_TAG]}"
IMAGE_TAG="${2:-$(date +%Y%m%d%H%M%S)}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim

REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"
REGION="$(echo "${REGISTRY}" | cut -d. -f4)"

echo "=== 2/4  Logging in to nvcr.io and ECR ==="
# --password-stdin keeps the key out of the process list.
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin

echo "=== 3/4  Building and pushing ${REPO_URL}:${IMAGE_TAG} ==="
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT_DIR}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint (this waits until InService) ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint ${ENDPOINT} is InService."
echo "Logs:      aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling:   aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region ${REGION}"
echo "Test:      python scripts/load_test.py --endpoint-name ${ENDPOINT} --region ${REGION} --rps 1 --duration 5"
