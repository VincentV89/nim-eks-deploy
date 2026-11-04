#!/usr/bin/env bash
# Deploy NVIDIA NIM to an Amazon SageMaker real-time endpoint.
#
# Usage: NGC_API_KEY=<key> ./scripts/deploy.sh
#
#   1. terraform apply  -> ECR repo, NGC secret container, SageMaker execution role
#   2. store the NGC key in Secrets Manager (never in Terraform state)
#   3. pull the NIM image from nvcr.io, add the SageMaker shim, push to ECR
#   4. terraform apply  -> SageMaker model, endpoint config, endpoint, autoscaling
#   5. wait for the endpoint to be InService
#
# Optional env vars:
#   NIM_IMAGE   NIM base image (default: nvcr.io/nim/meta/llama-3.1-8b-instruct:latest)
#   NIM_USER    non-root user to run as (default: the NIM image's configured user)
#   IMAGE_TAG   ECR tag to push (default: <git sha>-<UTC timestamp>)
#   AWS_REGION  must match terraform's `region` (default: us-east-1)
set -euo pipefail

: "${NGC_API_KEY:?Set NGC_API_KEY in the environment (it is not accepted as an argument so it stays out of shell history and ps)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo local)-$(date -u +%Y%m%d%H%M%S)}"

for bin in aws docker terraform; do
  command -v "${bin}" >/dev/null || { echo "error: '${bin}' is required" >&2; exit 1; }
done

tf() { terraform -chdir="${TF_DIR}" "$@"; }

echo "=== 1/5  Creating ECR repository, NGC secret and IAM role ==="
tf init -input=false
tf apply -input=false -auto-approve -var "region=${AWS_REGION}"
ECR_REPO="$(tf output -raw ecr_repository_url)"
SECRET_ARN="$(tf output -raw ngc_secret_arn)"

echo "=== 2/5  Storing NGC API key in Secrets Manager ==="
# Pass the value through a 0600 temp file rather than the command line.
secret_file="$(mktemp)"
trap 'rm -f "${secret_file}"' EXIT
chmod 600 "${secret_file}"
printf '%s' "${NGC_API_KEY}" > "${secret_file}"
aws secretsmanager put-secret-value --secret-id "${SECRET_ARN}" \
  --secret-string "file://${secret_file}" >/dev/null
rm -f "${secret_file}"

echo "=== 3/5  Building SageMaker image ${ECR_REPO}:${IMAGE_TAG} ==="
printf '%s' "${NGC_API_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker pull --platform linux/amd64 "${NIM_IMAGE}"
docker logout nvcr.io >/dev/null

NIM_USER="${NIM_USER:-$(docker image inspect --format '{{.Config.User}}' "${NIM_IMAGE}")}"
if [[ -z "${NIM_USER}" || "${NIM_USER}" == "root" || "${NIM_USER}" == "0" ]]; then
  echo "error: ${NIM_IMAGE} has no non-root USER; set NIM_USER explicitly" >&2
  exit 1
fi

docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  --build-arg NIM_USER="${NIM_USER}" \
  -t "${ECR_REPO}:${IMAGE_TAG}" "${ROOT}/sagemaker"

aws ecr get-login-password | docker login "${ECR_REPO%%/*}" --username AWS --password-stdin
docker push "${ECR_REPO}:${IMAGE_TAG}"

echo "=== 4/5  Creating SageMaker model, endpoint and autoscaling ==="
# Persist the tag so later plain `terraform apply` runs keep (not delete) the endpoint.
printf 'image_tag = "%s"\n' "${IMAGE_TAG}" > "${TF_DIR}/image.auto.tfvars"
tf apply -input=false -auto-approve -var "region=${AWS_REGION}"
ENDPOINT="$(tf output -raw endpoint_name)"

echo "=== 5/5  Waiting for endpoint ${ENDPOINT} to be InService (first boot ~10-20 min) ==="
aws sagemaker wait endpoint-in-service --endpoint-name "${ENDPOINT}"

echo ""
echo "Done! Endpoint ${ENDPOINT} is InService."
echo "Test:       python scripts/load_test.py ${ENDPOINT} --rps 1 --duration 5"
echo "Logs:       aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow"
echo "Scaling:    aws application-autoscaling describe-scaling-activities --service-namespace sagemaker"
