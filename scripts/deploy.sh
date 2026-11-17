#!/usr/bin/env bash
# Deploy NIM to a SageMaker real-time endpoint.
#   1. Create the ECR repo
#   2. Build the SageMaker-compatible NIM image and push it to ECR
#   3. Create the SageMaker model, endpoint and GPU autoscaling policy
# Usage: ./scripts/deploy.sh <NGC_API_KEY> [image_tag]
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY> [image_tag]}"
IMAGE_TAG="${2:-$(date +%Y%m%d%H%M%S)}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="terraform -chdir=${ROOT}/terraform"

# Pass the key to Terraform via env, never on the command line
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/3  Creating ECR repository ==="
$TF init -input=false
$TF apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$($TF output -raw ecr_repository_url)"
REGION="$(cut -d. -f4 <<<"${REPO_URL}")"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/3  Building + pushing SageMaker NIM image (${IMAGE_TAG}) ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 3/3  Deploying SageMaker endpoint + autoscaling ==="
$TF apply -input=false -auto-approve

ENDPOINT="$($TF output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService (first boot builds the TensorRT engine)."
echo "Status:  aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Logs:    aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Test:    python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 1 --duration 5"
