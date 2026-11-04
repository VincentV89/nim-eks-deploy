#!/usr/bin/env bash
# Build the SageMaker-ready NIM image, push it to ECR, and deploy the SageMaker
# endpoint with GPU-based autoscaling.
# Usage: NGC_API_KEY=nvapi-... TF_STATE_BUCKET=my-state-bucket ./scripts/deploy.sh
#   Required env: NGC_API_KEY, and TF_STATE_BUCKET unless terraform/backend.hcl exists
#   Optional env: AWS_REGION (default us-east-1), EXPECTED_AWS_ACCOUNT_ID,
#                 TF_STATE_KEY, NIM_IMAGE, IMAGE_TAG
set -euo pipefail

: "${NGC_API_KEY:?Set NGC_API_KEY in the environment (avoid passing secrets as arguments)}"
REGION="${AWS_REGION:-us-east-1}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3}"   # pinned; never :latest
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}"   # unique tag => new SageMaker model on each deploy

case "${NIM_IMAGE}" in
  *:latest) echo "NIM_IMAGE must be pinned to a version tag or digest, not :latest" >&2; exit 1 ;;
esac
if [[ "${IMAGE_TAG}" == "latest" ]]; then
  echo "IMAGE_TAG must be unique (the ECR repository is tag-immutable)" >&2; exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"

# --- Confirm the target AWS account before touching anything ---
read -r ACCOUNT_ID CALLER_ARN < <(aws sts get-caller-identity --query '[Account, Arn]' --output text)
echo "Deploying to account ${ACCOUNT_ID} (${CALLER_ARN}) in ${REGION}"
if [[ -n "${EXPECTED_AWS_ACCOUNT_ID:-}" && "${ACCOUNT_ID}" != "${EXPECTED_AWS_ACCOUNT_ID}" ]]; then
  echo "Refusing to deploy: expected account ${EXPECTED_AWS_ACCOUNT_ID}, got ${ACCOUNT_ID}" >&2
  exit 1
fi

# --- Remote, encrypted Terraform state (it contains the NGC API key) ---
BACKEND_ARGS=()
if [[ -f "${TF_DIR}/backend.hcl" ]]; then
  BACKEND_ARGS=(-backend-config=backend.hcl)
else
  : "${TF_STATE_BUCKET:?Set TF_STATE_BUCKET (an S3 bucket for Terraform state) or create terraform/backend.hcl}"
  BACKEND_ARGS=(
    -backend-config="bucket=${TF_STATE_BUCKET}"
    -backend-config="key=${TF_STATE_KEY:-nim-sagemaker/terraform.tfstate}"
    -backend-config="region=${REGION}"
  )
fi

export TF_VAR_ngc_api_key="${NGC_API_KEY}" TF_VAR_region="${REGION}" TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false "${BACKEND_ARGS[@]}"
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
