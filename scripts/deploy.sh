#!/usr/bin/env bash
# Build the SageMaker-ready NIM image, push it to ECR and deploy the endpoint.
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
# Requires: aws, docker, terraform. Run from the repo root.
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

# Pass the key to Terraform via env so it never lands in a file or argv.
export TF_VAR_ngc_api_key="${NGC_KEY}"

echo "=== 1/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim

REGION="$(terraform -chdir="${TF_DIR}" console <<<'var.region' | tr -d '"')"
IMAGE_URI="$(terraform -chdir="${TF_DIR}" output -raw image_uri)"
REGISTRY="${IMAGE_URI%%/*}"

echo "=== 2/4  Building SageMaker shim on top of ${NIM_IMAGE} ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${IMAGE_URI}" "${REPO_ROOT}/sagemaker"

echo "=== 3/4  Pushing ${IMAGE_URI} ==="
aws ecr get-login-password --region "${REGION}" \
  | docker login "${REGISTRY}" --username AWS --password-stdin
docker push "${IMAGE_URI}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService (first boot builds the TensorRT engine)."
echo "Logs:     aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Status:   aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Scaling:  aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region ${REGION}"
