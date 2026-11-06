#!/usr/bin/env bash
# Deploy NVIDIA NIM (Llama 3.1 8B Instruct) to an Amazon SageMaker real-time endpoint.
#
#   1. Create the ECR repository (terraform, targeted)
#   2. Pull the NIM image from nvcr.io, wrap it with the SageMaker shim, push to ECR
#   3. Create the SageMaker model, endpoint and GPU autoscaling (terraform)
#
# Usage: NGC_API_KEY=<key> ./scripts/deploy.sh      (preferred: keeps the key out of shell history)
#        ./scripts/deploy.sh <NGC_API_KEY>
set -euo pipefail

NGC_KEY="${NGC_API_KEY:-${1:-}}"
if [[ -z "${NGC_KEY}" ]]; then
  echo "Usage: NGC_API_KEY=<key> $0   (or $0 <NGC_API_KEY>)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}"

for cmd in terraform docker aws; do
  command -v "${cmd}" >/dev/null || { echo "ERROR: '${cmd}' is required" >&2; exit 1; }
done

export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_nim_image_tag="${IMAGE_TAG}"

echo "=== 1/3  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
ECR_REPO="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
ECR_REGISTRY="${ECR_REPO%%/*}"
REGION="$(echo "${ECR_REGISTRY}" | cut -d. -f4)"

echo "=== 2/3  Building SageMaker NIM image -> ${ECR_REPO}:${IMAGE_TAG} ==="
echo "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${ECR_REGISTRY}" --username AWS --password-stdin

docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${ECR_REPO}:${IMAGE_TAG}" -t "${ECR_REPO}:latest" \
  "${REPO_ROOT}/container"
docker push "${ECR_REPO}:${IMAGE_TAG}"
docker push "${ECR_REPO}:latest"

echo "=== 3/3  Deploying SageMaker endpoint (model download + engine build: ~10-20 min) ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Test it:     $(terraform -chdir="${TF_DIR}" output -raw invoke_example)"
echo "Load test:   python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 20 --duration 120"
echo "Logs:        aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
