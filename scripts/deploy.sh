#!/usr/bin/env bash
# Deploy NVIDIA NIM to an Amazon SageMaker real-time endpoint.
#
#   1. Create the ECR repository (Terraform, targeted)
#   2. Pull the NIM image from nvcr.io, wrap it for SageMaker, push to ECR
#   3. Create the SageMaker model, endpoint and autoscaling (Terraform)
#
# Usage: NGC_API_KEY=<key> ./scripts/deploy.sh
#   (the key is read from the environment so it doesn't land in shell history / ps output)
set -euo pipefail

: "${NGC_API_KEY:?Set NGC_API_KEY to your NVIDIA NGC API key}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
export TF_VAR_ngc_api_key="${NGC_API_KEY}"
export TF_VAR_image_tag="${IMAGE_TAG}"

for bin in terraform docker aws; do
  command -v "$bin" >/dev/null || { echo "ERROR: '$bin' is required" >&2; exit 1; }
done

echo "=== 1/3  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGION="$(cut -d. -f4 <<<"${REPO_URL}")"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/3  Building SageMaker-compatible NIM image -> ${REPO_URL}:${IMAGE_TAG} ==="
printf '%s' "${NGC_API_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
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
echo "Status:   aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Logs:     aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling:  aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region ${REGION}"
