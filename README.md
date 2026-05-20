# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on Amazon SageMaker with auto scaling.

## Architecture

```
User -> SageMaker Endpoint -> NIM Container on ml.g5.xlarge (A10G GPU)
                                      |
                   Auto scaling on SageMakerVariantInvocationsPerInstance
```

**Stack:** Terraform (infrastructure + deployment)

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform` installed
- `boto3` installed (for load test script)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free - needed to pull NIM images)
- ~$3.50/hr budget (one ml.g5.xlarge on-demand)

## Deploy

```bash
# 1. Configure variables
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit with your values (add NGC API key)

# 2. Deploy infrastructure and endpoint
terraform init && terraform apply

# 3. Wait for endpoint to become InService (~5-10 min on first deploy)
aws sagemaker wait endpoint-in-service \
  --endpoint-name $(terraform output -raw sagemaker_endpoint_name)
```

Alternatively, use the deploy script which automates all steps:

```bash
./scripts/deploy.sh <your-ngc-api-key>
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
