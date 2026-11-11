#!/usr/bin/env bash
# Deploy NIM to a SageMaker real-time endpoint with GPU autoscaling.
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
# Requires: aws, terraform, docker (with buildx for linux/amd64).
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="terraform -chdir=${ROOT}/terraform"

# Pass the key to Terraform via env so it never lands in tfvars or argv.
export TF_VAR_ngc_api_key="${NGC_KEY}"

echo "=== 1/4  Creating ECR repository + NGC secret ==="
${TF} init -input=false
${TF} apply -input=false -auto-approve \
  -target=aws_ecr_repository.nim \
  -target=aws_secretsmanager_secret_version.ngc

REPO_URL="$(${TF} output -raw ecr_repository_url)"
REGION="$(${TF} output -raw region)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/4  Pulling NIM image from NGC ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker pull --platform linux/amd64 "${NIM_IMAGE}"
NIM_START_CMD="$(docker inspect --format '{{join .Config.Entrypoint " "}} {{join .Config.Cmd " "}}' "${NIM_IMAGE}" | xargs)"
echo "NIM start command: ${NIM_START_CMD}"

echo "=== 3/4  Building SageMaker adapter image and pushing to ECR ==="
# Unique tag per build so Terraform creates a new model/endpoint config and
# SageMaker performs a rolling update.
IMAGE_TAG="$(date -u +%Y%m%d%H%M%S)"
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  --build-arg NIM_START_CMD="${NIM_START_CMD}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
# First boot downloads weights and builds the TensorRT engine; endpoint
# creation typically takes 10-20 min.
${TF} apply -input=false -auto-approve -var "image_tag=${IMAGE_TAG}"

ENDPOINT="$(${TF} output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Logs:     aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling:  aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query 'ProductionVariants[0].CurrentInstanceCount'"
echo "Test:     python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 1 --duration 5"
