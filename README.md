# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on Amazon SageMaker with auto scaling.

## Architecture

```
User -> SageMaker Endpoint -> NIM Container (ECR) on ml.g5.xlarge (A10G GPU)
                                      |
                   Auto scaling on SageMakerVariantInvocationsPerInstance
```

**Stack:** Terraform (infrastructure + deployment)

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform` installed
- `docker` installed (for pulling NIM image from NGC and pushing to ECR)
- `boto3` installed (for load test script)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free - needed to pull NIM images)
- ~$3.50/hr budget (one ml.g5.xlarge on-demand)

## Important: ECR Image Requirement

SageMaker cannot pull container images from the NGC private registry (`nvcr.io`) directly.
The deploy script automatically handles pulling the NIM image from NGC and pushing it to
a private ECR repository that Terraform creates. You need Docker installed and enough disk
space for the NIM image (~15-20 GB).

## Deploy

The deploy script automates all steps including the ECR image push:

```bash
export TF_VAR_ngc_api_key="<your-ngc-api-key>"
./scripts/deploy.sh
```

For manual deployment:

```bash
# 1. Configure variables
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit with your values

# 2. Set NGC API key as environment variable (avoids process-list exposure)
export TF_VAR_ngc_api_key="<your-ngc-api-key>"

# 3. Create ECR repository first
terraform init
terraform apply -target=aws_ecr_repository.nim

# 4. Push NIM image to ECR
ECR_REPO=$(terraform output -raw ecr_repository_url)
echo "${TF_VAR_ngc_api_key}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
docker pull nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR_REPO%%/*}"
docker tag nvcr.io/nim/meta/llama-3.1-8b-instruct:latest "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest"

# 5. Deploy full infrastructure
terraform apply

# 6. Wait for endpoint to become InService (~5-10 min on first deploy)
aws sagemaker wait endpoint-in-service \
  --endpoint-name $(terraform output -raw sagemaker_endpoint_name)
```

## Test It

```bash
ENDPOINT_NAME=$(cd terraform && terraform output -raw sagemaker_endpoint_name)

aws sagemaker-runtime invoke-endpoint \
  --endpoint-name "$ENDPOINT_NAME" \
  --content-type "application/json" \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  output.json

cat output.json
```

## Load Test

```bash
pip install boto3
python scripts/load_test.py <endpoint-name> --rps 20 --duration 120
```

Watch scaling activity in the AWS Console under SageMaker > Endpoints, or via:

```bash
aws sagemaker describe-endpoint --endpoint-name <endpoint-name>
```

## Teardown

```bash
cd terraform && terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker auto scaling | `terraform/main.tf` | Scales instances based on invocations per instance |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
