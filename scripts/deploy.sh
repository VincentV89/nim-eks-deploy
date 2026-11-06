#!/usr/bin/env bash
# Deploy NIM to a SageMaker real-time endpoint with GPU-based autoscaling.
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

export TF_VAR_ngc_api_key="${NGC_KEY}"
export NGC_API_KEY="${NGC_KEY}"

echo "=== 1/3  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -target=aws_ecr_repository.nim

REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGION="$(terraform -chdir="${TF_DIR}" console <<<'var.region' | tr -d '"')"
TAG="$(terraform -chdir="${TF_DIR}" console <<<'var.image_tag' | tr -d '"')"

echo "=== 2/3  Building + pushing SageMaker NIM image ==="
"${ROOT_DIR}/scripts/build_and_push.sh" "${REPO_URL}" "${TAG}" "${REGION}"

echo "=== 3/3  Creating SageMaker model, endpoint and autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Logs:     aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Status:   aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query EndpointStatus"
echo "Instances: aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} --query 'ProductionVariants[0].CurrentInstanceCount'"
