#!/usr/bin/env bash
# Build the SageMaker-ready NIM image, push it to ECR, and deploy the endpoint.
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
# Env:   AWS_REGION (default us-east-1), IMAGE_TAG, NIM_IMAGE
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
REGION="${AWS_REGION:-us-east-1}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-llama-3.1-8b-instruct-latest}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"

export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_region="${REGION}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/4  Logging in to nvcr.io and ECR ==="
# --password-stdin keeps the key out of the process list
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin

echo "=== 3/4  Building + pushing SageMaker NIM image ==="
# SageMaker GPU instances are x86_64
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/container"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
# Endpoint creation waits until InService (NIM first boot ~10-20 min).
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! SageMaker endpoint '${ENDPOINT}' is InService."
echo "Test it:     python scripts/invoke.py --endpoint ${ENDPOINT} --region ${REGION}"
echo "Logs:        aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling:     aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region ${REGION}"
