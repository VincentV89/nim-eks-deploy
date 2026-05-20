#!/usr/bin/env bash
# Deploy NVIDIA NIM on Amazon SageMaker via Terraform.
#
# Prerequisites:
#   - docker (for pulling from nvcr.io and pushing to ECR)
#   - aws CLI configured with appropriate permissions
#   - terraform installed
#
# Usage:
#   export TF_VAR_ngc_api_key="<your-ngc-api-key>"
#   ./deploy.sh
#
# The NGC API key is read from the TF_VAR_ngc_api_key environment variable
# to avoid exposing it in the process list (which would happen with -var CLI flags).
set -euo pipefail

if [[ -z "${TF_VAR_ngc_api_key:-}" ]]; then
  echo "ERROR: TF_VAR_ngc_api_key environment variable is not set."
  echo "Usage:"
  echo "  export TF_VAR_ngc_api_key=\"<your-ngc-api-key>\""
  echo "  ./deploy.sh"
  exit 1
fi

NGC_IMAGE="nvcr.io/nim/meta/llama-3.1-8b-instruct:latest"

echo "=== 1/6  Initializing Terraform ==="
terraform -chdir=terraform init

echo "=== 2/6  Creating ECR repository (if not exists) ==="
terraform -chdir=terraform apply -auto-approve -target=aws_ecr_repository.nim

echo "=== 3/6  Pushing NIM image from nvcr.io to ECR ==="
ECR_REPO=$(terraform -chdir=terraform output -raw ecr_repository_url 2>/dev/null || \
  aws ecr describe-repositories --repository-names nim-llama-3-1-8b --query 'repositories[0].repositoryUri' --output text)
AWS_REGION=$(terraform -chdir=terraform output -raw aws_region 2>/dev/null || echo "us-east-1")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Login to NGC registry
echo "${TF_VAR_ngc_api_key}" | docker login nvcr.io --username '$oauthtoken' --password-stdin

# Pull the NIM image from NGC
docker pull "${NGC_IMAGE}"

# Login to ECR
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Tag and push to ECR
docker tag "${NGC_IMAGE}" "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest"
echo "Image pushed to ECR: ${ECR_REPO}:latest"

echo "=== 4/6  Applying full Terraform configuration ==="
terraform -chdir=terraform apply -auto-approve

echo "=== 5/6  Waiting for endpoint to become InService ==="
ENDPOINT_NAME=$(terraform -chdir=terraform output -raw sagemaker_endpoint_name)
echo "Endpoint: ${ENDPOINT_NAME}"
aws sagemaker wait endpoint-in-service --endpoint-name "${ENDPOINT_NAME}"
echo "Endpoint is InService."

echo "=== 6/6  Testing endpoint with sample invocation ==="
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
