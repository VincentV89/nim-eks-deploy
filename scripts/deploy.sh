#!/usr/bin/env bash
# Deploy NIM as an Amazon SageMaker real-time endpoint with GPU autoscaling.
#
#   1. Create the ECR repository (Terraform, targeted)
#   2. Pull the NIM image from nvcr.io, wrap it with the SageMaker shim, push to ECR
#   3. Create the SageMaker model, endpoint and autoscaling policy (Terraform)
#
# Usage: ./scripts/deploy.sh <NGC_API_KEY> [AWS_REGION]
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY> [AWS_REGION]}"
REGION="${2:-${AWS_REGION:-us-east-1}}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-llama-3.1-8b-instruct-$(date +%Y%m%d%H%M%S)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"

# Pass secrets to Terraform via env, never on the command line.
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_region="${REGION}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/3  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/3  Building SageMaker-compatible NIM image (${IMAGE_TAG}) ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 3/3  Creating SageMaker endpoint + autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve
ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"

echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Logs:     aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling:  aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region ${REGION}"
echo "Test:     python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 1 --duration 5"
