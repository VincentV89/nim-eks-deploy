#!/usr/bin/env bash
# Build the NIM SageMaker image, push it to ECR, and deploy the SageMaker endpoint.
# Usage: ./scripts/deploy.sh <NGC_API_KEY>
# Requires: aws, docker, terraform. Run from the repository root.
set -euo pipefail

NGC_KEY="${1:?Usage: ./scripts/deploy.sh <NGC_API_KEY>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"

tf() { terraform -chdir="${TF_DIR}" "$@"; }

echo "=== 1/4  Creating ECR repository + NGC secret ==="
tf init -input=false
tf apply -input=false -auto-approve \
  -target=aws_ecr_repository.nim \
  -target=aws_secretsmanager_secret.ngc

REPO_URL="$(tf output -raw ecr_repository_url)"
REGION="${REPO_URL#*.dkr.ecr.}"   # <acct>.dkr.ecr.<region>.amazonaws.com/<repo>
REGION="${REGION%%.*}"
SECRET_ARN="$(tf output -raw ngc_secret_arn)"

echo "=== 2/4  Storing NGC API key in Secrets Manager ==="
# Passed via stdin-backed file so the key does not appear in the process list.
aws secretsmanager put-secret-value --region "${REGION}" \
  --secret-id "${SECRET_ARN}" \
  --secret-string file:///dev/stdin <<<"${NGC_KEY}" >/dev/null

echo "=== 3/4  Building + pushing SageMaker-compatible NIM image ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" \
  | docker login "${REPO_URL%%/*}" --username AWS --password-stdin
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "=== 4/4  Deploying SageMaker endpoint + autoscaling ==="
# Endpoint creation blocks until the endpoint is InService (NIM first boot
# downloads weights and loads the TensorRT-LLM engine: ~10-20 min).
tf apply -input=false -auto-approve -var="image_tag=${IMAGE_TAG}"

ENDPOINT="$(tf output -raw endpoint_name)"
echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService."
echo "Logs:     aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Status:   aws sagemaker describe-endpoint --endpoint-name ${ENDPOINT} --region ${REGION}"
echo "Load test: python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 20 --duration 120"
