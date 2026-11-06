#!/usr/bin/env bash
# Deploy NIM (Llama 3.1 8B Instruct) to an autoscaling SageMaker real-time endpoint.
#
#   1. Store the NGC API key in Secrets Manager (never in Terraform state)
#   2. Create the ECR repository
#   3. Build the SageMaker-adapted NIM image (container/) and push it to ECR
#   4. Create the SageMaker model, endpoint and autoscaling policy
#
# Usage: NGC_API_KEY=<key> ./scripts/deploy.sh
#   Requires: aws, docker, terraform. Run from the repository root.
set -euo pipefail

: "${NGC_API_KEY:?Set NGC_API_KEY in the environment (kept out of argv/shell history)}"

REGION="${AWS_REGION:-us-east-1}"
SECRET_NAME="${NGC_SECRET_NAME:-nim-demo/ngc-api-key}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-llama-3.1-8b-instruct-$(date +%Y%m%d%H%M%S)}"
TF_DIR="terraform"

echo "=== 1/4  Storing NGC API key in Secrets Manager (${SECRET_NAME}) ==="
if SECRET_ARN="$(aws secretsmanager describe-secret --region "${REGION}" \
      --secret-id "${SECRET_NAME}" --query ARN --output text 2>/dev/null)"; then
  aws secretsmanager put-secret-value --region "${REGION}" \
    --secret-id "${SECRET_ARN}" --secret-string "${NGC_API_KEY}" >/dev/null
else
  SECRET_ARN="$(aws secretsmanager create-secret --region "${REGION}" \
    --name "${SECRET_NAME}" --secret-string "${NGC_API_KEY}" \
    --query ARN --output text)"
fi

TF_VARS=(-var "region=${REGION}" -var "ngc_secret_arn=${SECRET_ARN}" -var "image_tag=${IMAGE_TAG}")

echo "=== 2/4  Creating ECR repository ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve \
  -target=aws_ecr_repository.nim "${TF_VARS[@]}"
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo "=== 3/4  Building and pushing SageMaker NIM image (${IMAGE_TAG}) ==="
# Pull the base image from NGC. The key is piped via stdin, never passed as an argument.
printf '%s' "${NGC_API_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" \
  | docker login "${REGISTRY}" --username AWS --password-stdin

docker build --platform linux/amd64 \
  --build-arg "NIM_IMAGE=${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" container/
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
# Blocks until the endpoint is InService (first boot builds the TensorRT engine, ~10-20 min).
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve "${TF_VARS[@]}"

ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Test it:       ./scripts/invoke.sh ${ENDPOINT} 'Hello'"
echo "Logs:          aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Instance count: aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION} \\"
echo "                  --query 'ProductionVariants[0].CurrentInstanceCount'"
