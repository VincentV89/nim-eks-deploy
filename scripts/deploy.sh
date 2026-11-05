#!/usr/bin/env bash
# Deploy NIM as an Amazon SageMaker real-time endpoint with GPU autoscaling.
#
#   1. Create the ECR repository and NGC secret (Terraform, targeted) and store
#      the NGC key in Secrets Manager
#   2. Pull the NIM image from nvcr.io (pinned to its digest), wrap it with the
#      SageMaker shim, push to ECR
#   3. Create the SageMaker model, endpoint and autoscaling policy (Terraform)
#
# Usage: NGC_API_KEY=nvapi-... ./scripts/deploy.sh [AWS_REGION]
#        ./scripts/deploy.sh [AWS_REGION]     # prompts for the key (no echo)
#
# The NGC key is never accepted as an argument (shell history, `ps`) and never
# passed to Terraform (state).
set -euo pipefail

REGION="${1:-${AWS_REGION:-us-east-1}}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
IMAGE_TAG="${IMAGE_TAG:-llama-3.1-8b-instruct-$(date +%Y%m%d%H%M%S)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"

# --- Preflight ---
for cmd in aws terraform docker; do
  command -v "${cmd}" >/dev/null || { echo "Required command not found: ${cmd}" >&2; exit 1; }
done
aws sts get-caller-identity --region "${REGION}" --query Arn --output text >/dev/null \
  || { echo "AWS credentials are not valid for region ${REGION}" >&2; exit 1; }

NGC_KEY="${NGC_API_KEY:-}"
if [[ -z "${NGC_KEY}" ]]; then
  read -rsp "NGC API key: " NGC_KEY; echo
fi
[[ -n "${NGC_KEY}" ]] || { echo "NGC API key required (set NGC_API_KEY or enter it at the prompt)" >&2; exit 1; }
unset NGC_API_KEY

[[ -f "${TF_DIR}/backend.tf" ]] || echo "WARNING: no terraform/backend.tf, state is local. See terraform/backend.tf.example." >&2

export TF_VAR_region="${REGION}"
export TF_VAR_image_tag="${IMAGE_TAG}"

# Remove the NGC credential from ~/.docker/config.json even if the build fails.
trap 'docker logout nvcr.io >/dev/null 2>&1 || true' EXIT

echo "=== 1/3  Creating ECR repository and NGC secret ==="
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve \
  -target=aws_ecr_repository.nim -target=aws_secretsmanager_secret.ngc
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
SECRET_ARN="$(terraform -chdir="${TF_DIR}" output -raw ngc_secret_arn)"
REGISTRY="${REPO_URL%%/*}"
printf '%s' "${NGC_KEY}" | aws secretsmanager put-secret-value --region "${REGION}" \
  --secret-id "${SECRET_ARN}" --secret-string file:///dev/stdin >/dev/null

echo "=== 2/3  Building SageMaker-compatible NIM image (${IMAGE_TAG}) ==="
printf '%s' "${NGC_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker pull --platform linux/amd64 "${NIM_IMAGE}"
# Pin the base image to the digest that was actually pulled.
NIM_DIGEST_REF="$(docker image inspect --format '{{index .RepoDigests 0}}' "${NIM_IMAGE}")"
# Read the upstream user and start command instead of assuming them.
UPSTREAM_USER="$(docker image inspect --format '{{.Config.User}}' "${NIM_IMAGE}")"
UPSTREAM_CMD="$(docker image inspect --format '{{join .Config.Entrypoint " "}} {{join .Config.Cmd " "}}' "${NIM_IMAGE}" | xargs)"
NIM_UID="${NIM_UID:-${UPSTREAM_USER:-1000}}"
echo "Base image: ${NIM_DIGEST_REF}  user=${NIM_UID}  start='${NIM_START_CMD:-${UPSTREAM_CMD}}'"

BUILD_ARGS=(--build-arg NIM_IMAGE="${NIM_DIGEST_REF}" --build-arg NIM_UID="${NIM_UID}")
if [[ -n "${NIM_START_CMD:-${UPSTREAM_CMD}}" ]]; then
  BUILD_ARGS+=(--build-arg NIM_START_CMD="${NIM_START_CMD:-${UPSTREAM_CMD}}")
fi

aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin
docker build --platform linux/amd64 "${BUILD_ARGS[@]}" \
  --label "org.opencontainers.image.base.name=${NIM_DIGEST_REF}" \
  -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT}/sagemaker"
docker push "${REPO_URL}:${IMAGE_TAG}"
docker logout nvcr.io >/dev/null 2>&1 || true

# Record the pushed tag so later plain `terraform apply` runs use the same image.
printf 'image_tag = "%s"\n' "${IMAGE_TAG}" > "${TF_DIR}/image.auto.tfvars"
unset TF_VAR_image_tag

echo "=== 3/3  Creating SageMaker endpoint + autoscaling ==="
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve
ENDPOINT="$(terraform -chdir="${TF_DIR}" output -raw endpoint_name)"

echo ""
echo "Done! Endpoint '${ENDPOINT}' is InService (image tag ${IMAGE_TAG}, recorded in terraform/image.auto.tfvars)."
echo "Logs:     aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Scaling:  aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region ${REGION}"
echo "Test:     python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 1 --duration 5"
