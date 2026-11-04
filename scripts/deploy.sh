#!/usr/bin/env bash
# Build the SageMaker-ready NIM image, push it to ECR, and deploy the SageMaker
# endpoint with GPU-based autoscaling.
# Usage: NGC_API_KEY=nvapi-... ./scripts/deploy.sh
#   Optional env: AWS_REGION (default us-east-1), NIM_IMAGE, IMAGE_TAG
set -euo pipefail

: "${NGC_API_KEY:?Set NGC_API_KEY in the environment (avoid passing secrets as arguments)}"
REGION="${AWS_REGION:-us-east-1}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}"   # unique tag => new SageMaker model on each deploy

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
export TF_VAR_ngc_api_key="${NGC_API_KEY}" TF_VAR_region="${REGION}" TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/4  Pulling NIM image from NGC ==="
printf '%s' "${NGC_API_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker pull --platform linux/amd64 "${NIM_IMAGE}"

echo "=== 3/4  Building SageMaker shim and pushing to ECR ==="
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint (NIM build/warm-up takes ~10-20 min) ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Status:     aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Logs:       aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Load test:  python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 20 --duration 120"
