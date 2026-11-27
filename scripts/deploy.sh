#!/usr/bin/env bash
# Build the SageMaker-compatible NIM image, push it to ECR and deploy the
# SageMaker endpoint (with GPU-based autoscaling) via Terraform.
#
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
# Env:   AWS_REGION  (default us-east-1)
#        NIM_IMAGE   (default nvcr.io/nim/meta/llama-3.1-8b-instruct:latest)
#        IMAGE_TAG   (default: UTC timestamp, so every run rolls the endpoint)
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
REGION="${AWS_REGION:-us-east-1}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

# Keep the key out of argv / shell history for child processes.
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_region="${REGION}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/4  Building SageMaker wrapper for ${NIM_IMAGE} ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" \
  "${ROOT_DIR}/sagemaker"

echo "=== 3/4  Pushing ${REPO_URL}:${IMAGE_TAG} ==="
aws ecr get-login-password --region "${REGION}" \
  | docker login "${REGISTRY}" --username AWS --password-stdin
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService (first boot builds the TensorRT engine)."
echo "Logs:    aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling: aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region ${REGION}"
