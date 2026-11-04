#!/usr/bin/env bash
# Build the SageMaker NIM image, push it to ECR and deploy the SageMaker endpoint.
#
# Usage:
#   export NGC_API_KEY=...        # or omit and you will be prompted (input hidden)
#   ./scripts/deploy.sh
#
# Optional env:
#   NIM_IMAGE   NIM container to wrap (default below)
#   SKIP_APPLY  set to 1 to only build/push and write image.auto.tfvars
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3}"

for bin in aws docker terraform git; do
  command -v "$bin" >/dev/null || { echo "ERROR: '$bin' is required" >&2; exit 1; }
done

if [[ -z "${NGC_API_KEY:-}" ]]; then
  read -rsp "NGC API key: " NGC_API_KEY; echo
fi
[[ -n "${NGC_API_KEY}" ]] || { echo "ERROR: NGC API key is empty" >&2; exit 1; }

echo "=== 0/5  Checking AWS credentials ==="
aws sts get-caller-identity --query Arn --output text

# Use a throwaway Docker config so registry credentials don't persist in ~/.docker.
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "${DOCKER_CONFIG}"' EXIT

tf() { terraform -chdir="${TF_DIR}" "$@"; }

echo "=== 1/5  Creating ECR repo, NGC secret and IAM role (terraform stage 1) ==="
tf init -input=false >/dev/null
# Stage 1 keeps any previously deployed image_tag (from image.auto.tfvars) so an
# existing endpoint is left untouched.
tf apply -input=false -auto-approve \
  -target=aws_ecr_repository.nim -target=aws_ecr_lifecycle_policy.nim \
  -target=aws_secretsmanager_secret.ngc -target=aws_iam_role_policy.sagemaker

REGION="$(tf output -raw region)"
ECR_URL="$(tf output -raw ecr_repository_url)"
SECRET_ARN="$(tf output -raw ngc_secret_arn)"
REGISTRY="${ECR_URL%%/*}"

echo "=== 2/5  Storing NGC API key in Secrets Manager ==="
# Pipe the value via stdin (printf is a builtin) so it never appears in the process list.
printf '%s' "${NGC_API_KEY}" | aws secretsmanager put-secret-value --region "${REGION}" \
  --secret-id "${SECRET_ARN}" --secret-string "file:///dev/stdin" >/dev/null

IMAGE_TAG="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain -- sagemaker)" ]]; then
  IMAGE_TAG="${IMAGE_TAG}-dirty-$(date +%Y%m%d%H%M%S)"
fi
IMAGE_TAG="${IMAGE_TAG}-${NIM_IMAGE##*:}"
IMAGE_TAG="${IMAGE_TAG//[^a-zA-Z0-9._-]/-}"

echo "=== 3/5  Building and pushing ${ECR_URL}:${IMAGE_TAG} ==="
if aws ecr describe-images --region "${REGION}" --repository-name "${ECR_URL#*/}" \
     --image-ids imageTag="${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "Image already in ECR, skipping build."
else
  docker login nvcr.io --username '$oauthtoken' --password-stdin <<<"${NGC_API_KEY}"
  docker pull --platform linux/amd64 "${NIM_IMAGE}"

  # Reuse NIM's own entrypoint/cmd/user rather than hard-coding them.
  NIM_START_CMD="$(docker inspect --format '{{join .Config.Entrypoint " "}} {{join .Config.Cmd " "}}' "${NIM_IMAGE}")"
  NIM_USER="$(docker inspect --format '{{.Config.User}}' "${NIM_IMAGE}")"

  docker build --platform linux/amd64 \
    --build-arg NIM_IMAGE="${NIM_IMAGE}" \
    --build-arg NIM_START_CMD="${NIM_START_CMD}" \
    --build-arg NIM_USER="${NIM_USER:-root}" \
    -t "${ECR_URL}:${IMAGE_TAG}" "${REPO_ROOT}/sagemaker"

  aws ecr get-login-password --region "${REGION}" \
    | docker login "${REGISTRY}" --username AWS --password-stdin
  docker push "${ECR_URL}:${IMAGE_TAG}"
fi

# Persist the tag so a later plain `terraform apply` doesn't tear down the endpoint.
printf 'image_tag = "%s"\n' "${IMAGE_TAG}" > "${TF_DIR}/image.auto.tfvars"

if [[ "${SKIP_APPLY:-0}" == "1" ]]; then
  echo "SKIP_APPLY=1 — run 'terraform -chdir=terraform apply' to deploy."
  exit 0
fi

echo "=== 4/5  Deploying SageMaker endpoint (terraform stage 2) ==="
tf apply -input=false -auto-approve

echo "=== 5/5  Done ==="
ENDPOINT="$(tf output -raw endpoint_name)"
echo "Endpoint '${ENDPOINT}' is InService (first boot downloads weights + builds the TRT-LLM engine)."
echo "Test:      $(tf output -raw test_command)"
echo "Logs:      aws logs tail /aws/sagemaker/Endpoints/${ENDPOINT} --follow --region ${REGION}"
echo "Load test: python scripts/load_test.py ${ENDPOINT} --region ${REGION} --rps 5 --duration 120"
