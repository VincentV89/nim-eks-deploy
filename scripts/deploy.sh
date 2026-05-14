#!/usr/bin/env bash
# Deploy NVIDIA NIM on Amazon SageMaker via Terraform.
# Usage: ./deploy.sh <NGC_API_KEY>
set -euo pipefail

NGC_KEY="${1:?Usage: ./deploy.sh <NGC_API_KEY>}"

echo "=== 1/3  Running Terraform ==="
cd "$(dirname "$0")/../terraform"
terraform init
terraform apply -auto-approve -var="ngc_api_key=$NGC_KEY"

echo "=== 2/3  Waiting for SageMaker endpoint to become InService ==="
ENDPOINT_NAME=$(terraform output -raw sagemaker_endpoint_name)
aws sagemaker wait endpoint-in-service --endpoint-name "$ENDPOINT_NAME"

echo "=== 3/3  Endpoint is InService ==="
echo ""
echo "Endpoint name: $ENDPOINT_NAME"
echo ""
echo "Sample invocation:"
echo "  aws sagemaker-runtime invoke-endpoint \\"
echo "    --endpoint-name \"$ENDPOINT_NAME\" \\"
echo "    --content-type application/json \\"
echo "    --body '{\"model\":\"meta/llama-3.1-8b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}' \\"
echo "    /dev/stdout"
