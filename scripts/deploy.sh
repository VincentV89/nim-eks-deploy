#!/usr/bin/env bash
# Build the SageMaker-adapted NIM image, push it to ECR, and deploy the endpoint.
# Usage: ./scripts/deploy.sh <NGC_API_KEY>      (run from repo root)
# Env:   AWS_REGION (default us-east-1), IMAGE_TAG (default: git short SHA)
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
REGION="${AWS_REGION:-us-east-1}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Pass secrets to Terraform via env, never on the command line.
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_region="${REGION}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${ROOT}/terraform" init -input=false
terraform -chdir="${ROOT}/terraform" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${ROOT}/terraform" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/4  Building SageMaker-adapted NIM image ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker build --platform linux/amd64 -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/container"

echo "=== 3/4  Pushing image to ECR ==="
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
terraform -chdir="${ROOT}/terraform" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${ROOT}/terraform" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService (first boot builds the TensorRT engine)."
echo "Status:  aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Logs:    aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
