#!/usr/bin/env bash
# Deploy NIM (Llama 3.1 8B Instruct) to an Amazon SageMaker real-time endpoint.
#
#   1. targeted terraform apply (ECR repo, IAM role, NGC secret)
#   2. pull the NIM image from nvcr.io, wrap it with the SageMaker shim, push to ECR
#   3. terraform apply (SageMaker model, endpoint, autoscaling)
#
# Usage: ./scripts/deploy.sh <NGC_API_KEY>      (or set NGC_API_KEY in the env)
# Requires: aws, docker, terraform
set -euo pipefail

NGC_KEY="${1:-${NGC_API_KEY:-}}"
[[ -n "${NGC_KEY}" ]] || { echo "Usage: ./scripts/deploy.sh <NGC_API_KEY>" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-llama-3.1-8b-instruct}"

for bin in aws docker terraform; do
  command -v "${bin}" >/dev/null || { echo "Missing required tool: ${bin}" >&2; exit 1; }
done

# Pass the key to Terraform via env, never on the command line
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_image_tag="${IMAGE_TAG}"

echo "=== 1/3  Provisioning ECR, IAM and NGC secret ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve \
  -target=aws_ecr_repository.nim \
  -target=aws_secretsmanager_secret_version.ngc \
  -target=aws_iam_role_policy.sagemaker

REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"
REGION="$(terraform -chdir="${TF_DIR}" output -raw region)"

echo "=== 2/3  Building SageMaker-compatible NIM image -> ${REPO_URL}:${IMAGE_TAG} ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker pull --platform linux/amd64 "${NIM_IMAGE}"
NIM_CMD="$(docker inspect --format '{{join .Config.Entrypoint " "}} {{join .Config.Cmd " "}}' "${NIM_IMAGE}" | xargs)"
[[ -n "${NIM_CMD}" ]] || { echo "Could not determine NIM start command from ${NIM_IMAGE}" >&2; exit 1; }
echo "NIM start command: ${NIM_CMD}"

docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  --build-arg NIM_CMD="${NIM_CMD}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/container"

aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 3/3  Creating SageMaker endpoint + autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService (NIM model download + TensorRT engine build happen on first boot)."
echo "Logs:    aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Status:  aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
