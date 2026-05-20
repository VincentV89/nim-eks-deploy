#!/usr/bin/env bash
# Deploy NVIDIA NIM on Amazon SageMaker via Terraform.
# Usage: ./deploy.sh <NGC_API_KEY>
set -euo pipefail

NGC_KEY="${1:?Usage: ./deploy.sh <NGC_API_KEY>}"

echo "=== 1/4  Initializing Terraform ==="
terraform -chdir=terraform init

echo "=== 2/4  Applying Terraform (provisions SageMaker endpoint) ==="
terraform -chdir=terraform apply -auto-approve -var "ngc_api_key=${NGC_KEY}"

echo "=== 3/4  Waiting for endpoint to become InService ==="
ENDPOINT_NAME=$(terraform -chdir=terraform output -raw sagemaker_endpoint_name)
echo "Endpoint: ${ENDPOINT_NAME}"
aws sagemaker wait endpoint-in-service --endpoint-name "${ENDPOINT_NAME}"
echo "Endpoint is InService."

echo "=== 4/4  Testing endpoint with sample invocation ==="
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name "${ENDPOINT_NAME}" \
  --content-type "application/json" \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello!"}],"max_tokens":50}' \
  /tmp/nim-test-response.json

echo ""
echo "Response:"
cat /tmp/nim-test-response.json
echo ""
echo ""
echo "Done! SageMaker endpoint '${ENDPOINT_NAME}' is live and serving requests."
echo "Invoke:  aws sagemaker-runtime invoke-endpoint --endpoint-name ${ENDPOINT_NAME} --content-type application/json --body '<payload>' output.json"
