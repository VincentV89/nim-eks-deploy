#!/usr/bin/env bash
# Build the NIM SageMaker image, push it to ECR and deploy the SageMaker
# endpoint (with GPU-based autoscaling) via Terraform.
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
# Env:   AWS_REGION (default us-east-1), NIM_IMAGE (default Llama 3.1 8B Instruct NIM)
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
REGION="${AWS_REGION:-us-east-1}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

# Pass secrets/inputs to Terraform via environment, never on the command line.
export TF_VAR_ngc_api_key="${NGC_KEY}"
export TF_VAR_region="${REGION}"
export TF_VAR_image_tag="${IMAGE_TAG}"

for bin in aws docker terraform; do
  command -v "${bin}" >/dev/null || { echo "ERROR: '${bin}' is required but not installed." >&2; exit 1; }
done

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 2/4  Building SageMaker-compatible NIM image ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" \
  "${ROOT_DIR}/sagemaker"

echo "=== 3/4  Pushing image to ECR ==="
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker push "${REPO_URL}:${IMAGE_TAG}"
IMAGE_DIGEST="$(aws ecr describe-images --region "${REGION}" \
  --repository-name "${REPO_URL#*/}" --image-ids imageTag="${IMAGE_TAG}" \
  --query 'imageDetails[0].imageDigest' --output text)"
export TF_VAR_image_digest="${IMAGE_DIGEST}"
echo "Pushed ${REPO_URL}@${IMAGE_DIGEST}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
# The endpoint only reaches InService once /ping succeeds, i.e. after NIM has
# downloaded the weights and built the TensorRT-LLM engine (~10-20 min).
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve
ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"

echo ""
echo "Done! SageMaker endpoint '${ENDPOINT}' is InService."
echo "Status:     aws sagemaker describe-endpoint --region ${REGION} --endpoint-name ${ENDPOINT} --query EndpointStatus"
echo "Logs:       aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --region ${REGION} --follow"
echo "Load test:  python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 20 --duration 120"
