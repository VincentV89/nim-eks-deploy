# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with Application Auto Scaling.

## Architecture

```
User -> SageMaker Endpoint -> NIM Container (ml.g5.xlarge, A10G GPU)
                                   |
                        Application Auto Scaling
                  (scales on InvocationsPerInstance metric)
```

**Stack:** Terraform (infra + SageMaker endpoint + auto-scaling)

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform` installed
- Python 3.9+ with `boto3` (for load testing)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free - needed to pull NIM images)
- ~$3.50/hr budget (one ml.g5.xlarge on-demand)

## Deploy (10 minutes)

```bash
# 1. Provision infrastructure and SageMaker endpoint
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit with your values
terraform init && terraform apply

# 2. Or use the deploy script (handles init, apply, and waits for InService)
cd ..
./scripts/deploy.sh <your-ngc-api-key>
```

## Test

```bash
ENDPOINT_NAME=$(cd terraform && terraform output -raw sagemaker_endpoint_name)

aws sagemaker-runtime invoke-endpoint \
  --endpoint-name "$ENDPOINT_NAME" \
  --content-type "application/json" \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py --endpoint-name "$ENDPOINT_NAME" --rps 20 --duration 120
```

Watch scaling activity:

```bash
aws application-autoscaling describe-scaling-activities \
  --service-namespace sagemaker \
  --resource-id "endpoint/nim-llm/variant/AllTraffic"
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
| Managed endpoint | `terraform/main.tf` | AWS handles provisioning, health checks, and instance lifecycle |
| Auto scaling policy | `terraform/main.tf` | Scales instances based on InvocationsPerInstance metric |
| Container serving | SageMaker model resource | Runs NIM container image on managed GPU infrastructure |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
