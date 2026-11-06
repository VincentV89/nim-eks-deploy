#!/usr/bin/env bash
# Deploy NIM (Llama 3.1 8B Instruct) to an Amazon SageMaker real-time endpoint.
#
#   1. Create the ECR repository (terraform -target)
#   2. Pull the NIM image from nvcr.io, wrap it with the SageMaker shim, push to ECR
#   3. Create the SageMaker model, endpoint and GPU-based autoscaling (terraform)
#
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
# Requires: aws, docker, terraform
set -euo pipefail

NGC_KEY="${1:-${NGC_API_KEY:-}}"
if [[ -z "${NGC_KEY}" ]]; then
  echo "Usage: ./scripts/deploy.sh <NGC_API_KEY>   (or export NGC_API_KEY)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
export TF_VAR_ngc_api_key="${NGC_KEY}"

for bin in aws docker terraform; do
  command -v "${bin}" >/dev/null || { echo "Missing required tool: ${bin}" >&2; exit 1; }
done

echo "=== 1/3  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGION="$(cut -d. -f4 <<<"${REPO_URL}")"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/3  Building SageMaker-compatible NIM image ==="
# --password-stdin keeps the key out of the process list.
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker pull --platform linux/amd64 "${NIM_IMAGE}"
NIM_START_CMD="$(docker inspect --format '{{join .Config.Entrypoint " "}} {{join .Config.Cmd " "}}' "${NIM_IMAGE}" | xargs)"
echo "Detected NIM start command: ${NIM_START_CMD}"

docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  --build-arg NIM_START_CMD="${NIM_START_CMD}" \
  -t nim-sagemaker:local "${ROOT}/sagemaker"

# Content-derived tag so a rebuilt image triggers a new SageMaker model/endpoint config.
IMAGE_ID="$(docker image inspect --format '{{.Id}}' nim-sagemaker:local)"
IMAGE_TAG="llama-3.1-8b-instruct-${IMAGE_ID#sha256:}"
IMAGE_TAG="${IMAGE_TAG:0:34}"

aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker tag nim-sagemaker:local "${REPO_URL}:${IMAGE_TAG}"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 3/3  Creating SageMaker endpoint + autoscaling (takes ~10-20 min) ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -var "image_tag=${IMAGE_TAG}"

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Logs:      aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Test:      python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 1 --duration 5"
echo "Scaling:   aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query 'ProductionVariants[0].CurrentInstanceCount'"
