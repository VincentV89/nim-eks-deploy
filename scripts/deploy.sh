#!/usr/bin/env bash
# Build the SageMaker-compatible NIM image, push it to ECR, and deploy the
# SageMaker real-time endpoint with GPU autoscaling.
# Usage: ./scripts/deploy.sh <NGC_API_KEY> [image-tag]
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY> [image-tag]}"
IMAGE_TAG="${2:-latest}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

# Keep the key out of argv/state files on disk where possible.
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
ECR_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGION="$(echo "${ECR_URL}" | cut -d. -f4)"
REGISTRY="${ECR_URL%%/*}"

echo "=== 2/4  Pulling NIM image from NGC ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker pull --platform linux/amd64 "${NIM_IMAGE}"

echo "=== 3/4  Building SageMaker wrapper image and pushing to ECR ==="
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${ECR_URL}:${IMAGE_TAG}" "${REPO_ROOT}/docker"
docker push "${ECR_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint (this waits until InService) ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Logs:     aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling:  aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region ${REGION}"
echo "Test:     python scripts/load_test.py --sagemaker-endpoint ${ENDPOINT} --region ${REGION} --rps 1 --duration 5"
