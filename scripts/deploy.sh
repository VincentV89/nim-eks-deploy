#!/usr/bin/env bash
# Deploy NIM (Llama 3.1 8B Instruct) to an Amazon SageMaker real-time endpoint.
#
#   1. Creates the ECR repository (terraform, targeted apply)
#   2. Builds the SageMaker wrapper image on top of the NGC NIM image and pushes it to ECR
#   3. Applies the rest of the stack (model, endpoint, GPU autoscaling)
#
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
# Requires: aws, docker, terraform
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"

for cmd in aws docker terraform; do
  command -v "${cmd}" >/dev/null || { echo "ERROR: '${cmd}' is required" >&2; exit 1; }
done

# Pass the key to terraform via env, never on the command line.
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/3  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGION="$(terraform -chdir="${TF_DIR}" output -raw region)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/3  Building SageMaker NIM image -> ${REPO_URL}:${IMAGE_TAG} ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" \
  "${ROOT_DIR}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 3/3  Deploying SageMaker model, endpoint and autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService (first boot downloads weights + builds the TensorRT engine)."
echo "Status:  aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Logs:    aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Invoke:  terraform -chdir=terraform output -raw invoke_example"
