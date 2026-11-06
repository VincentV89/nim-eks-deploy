#!/usr/bin/env bash
# Build the SageMaker-compatible NIM image and push it to ECR.
# Usage: NGC_API_KEY=<key> ./scripts/build_and_push.sh <ecr-repo-url> <image-tag> [region]
set -euo pipefail

: "${NGC_API_KEY:?Set NGC_API_KEY in the environment}"
REPO_URL="${1:?Usage: build_and_push.sh <ecr-repo-url> <image-tag> [region]}"
TAG="${2:?Usage: build_and_push.sh <ecr-repo-url> <image-tag> [region]}"
REGION="${3:-us-east-1}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct:latest}"
REGISTRY="${REPO_URL%%/*}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if aws ecr describe-images --repository-name "${REPO_URL#*/}" --image-ids imageTag="${TAG}" \
     --region "${REGION}" >/dev/null 2>&1; then
  echo "Image ${REPO_URL}:${TAG} already exists (tags are immutable) — skipping build."
  exit 0
fi

echo "--- Logging in to nvcr.io and ECR ---"
printf '%s' "${NGC_API_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
aws ecr get-login-password --region "${REGION}" | docker login "${REGISTRY}" --username AWS --password-stdin

echo "--- Building ${REPO_URL}:${TAG} from ${NIM_IMAGE} ---"
docker build --platform linux/amd64 \
  --build-arg NIM_IMAGE="${NIM_IMAGE}" \
  -t "${REPO_URL}:${TAG}" "${ROOT_DIR}/container"

echo "--- Pushing ---"
docker push "${REPO_URL}:${TAG}"
