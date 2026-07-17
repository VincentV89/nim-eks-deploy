#!/usr/bin/env bash
# Deploy NVIDIA NIM on AWS SageMaker via Terraform and verify the endpoint.
# Usage: ./deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== 1/3  Initializing Terraform ==="
cd "${TF_DIR}"
terraform init -input=false

echo "=== 2/3  Applying Terraform (creates SageMaker endpoint) ==="
terraform apply -auto-approve -input=false

ENDPOINT_NAME=$(terraform output -raw endpoint_name)
REGION=$(terraform output -raw region)

echo "=== 3/3  Testing SageMaker endpoint ==="
echo "Endpoint: ${ENDPOINT_NAME}"
echo "Waiting for endpoint to be InService..."

aws sagemaker wait endpoint-in-service --endpoint-name "${ENDPOINT_NAME}" --region "${REGION}"

echo "Sending test inference request..."
RESPONSE=$(aws sagemaker-runtime invoke-endpoint \
  --endpoint-name "${ENDPOINT_NAME}" \
  --region "${REGION}" \
  --content-type "application/json" \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout 2>/dev/null)

echo "Response: ${RESPONSE}"
echo ""
echo "Done! SageMaker endpoint is live."
echo "Endpoint name: ${ENDPOINT_NAME}"
echo "To teardown:   cd terraform && terraform destroy"
