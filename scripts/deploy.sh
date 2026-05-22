#!/usr/bin/env bash
# Deploy NVIDIA NIM on Amazon SageMaker via Terraform.
# Usage: ./deploy.sh <NGC_API_KEY>
set -euo pipefail

NGC_KEY="${1:?Usage: ./deploy.sh <NGC_API_KEY>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

echo "=== 1/3  Running Terraform init and apply ==="
terraform -chdir="${TERRAFORM_DIR}" init
terraform -chdir="${TERRAFORM_DIR}" apply -auto-approve \
  -var="ngc_api_key=${NGC_KEY}"

echo "=== 2/3  Retrieving SageMaker endpoint name ==="
ENDPOINT_NAME=$(terraform -chdir="${TERRAFORM_DIR}" output -raw sagemaker_endpoint_name)
echo "Endpoint: ${ENDPOINT_NAME}"

echo "=== 3/3  Waiting for endpoint to become InService ==="
aws sagemaker wait endpoint-in-service --endpoint-name "${ENDPOINT_NAME}"

echo ""
echo "Done! SageMaker endpoint is InService."
echo "Endpoint name: ${ENDPOINT_NAME}"
echo ""
echo "Test with:"
echo "  aws sagemaker-runtime invoke-endpoint \\"
echo "    --endpoint-name ${ENDPOINT_NAME} \\"
echo "    --content-type application/json \\"
echo "    --body '{\"model\":\"meta/llama-3.1-8b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}' \\"
echo "    /dev/stdout"
