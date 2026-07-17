# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on AWS SageMaker with application auto scaling.

## Architecture

```
User (boto3 / AWS CLI)
        |
        v
SageMaker Endpoint (ml.g5.xlarge, A10G GPU)
        |
        v
NIM Container (nvcr.io/nim/meta/llama-3.1-8b-instruct)
        |
        v
Application Auto Scaling (scales instances based on invocations per instance)
```

**Stack:** Terraform (infrastructure) -> SageMaker (model serving) -> Auto Scaling (elasticity)

## Prerequisites

- AWS CLI configured with permissions for SageMaker, IAM, and Application Auto Scaling
- `terraform` >= 1.5 installed
- Python 3.9+ with `boto3` installed (for load testing)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free, needed to pull NIM model weights)
- ~$1.50/hr budget (one ml.g5.xlarge on-demand)

## Deploy

```bash
# 1. Configure variables
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars - set your ngc_api_key and region

# 2. Deploy via script (init + apply + test)
cd ..
./scripts/deploy.sh
```

Or manually:

```bash
cd terraform
terraform init
terraform apply
```

## Test the Endpoint

```bash
ENDPOINT_NAME=$(cd terraform && terraform output -raw endpoint_name)

aws sagemaker-runtime invoke-endpoint \
  --endpoint-name "${ENDPOINT_NAME}" \
  --region us-east-1 \
  --content-type "application/json" \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo auto scaling)

```bash
pip install boto3
python scripts/load_test.py --endpoint-name "${ENDPOINT_NAME}" --region us-east-1 --rps 20 --duration 120
```

Monitor scaling activity in the AWS Console under SageMaker > Endpoints, or via:

```bash
aws application-autoscaling describe-scaling-activities \
  --service-namespace sagemaker \
  --resource-id "endpoint/${ENDPOINT_NAME}/variant/primary"
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
| Application Auto Scaling | `terraform/main.tf` | Scales endpoint instances based on invocation load |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
| SageMaker Real-Time Inference | `terraform/main.tf` | Managed endpoint with health checks and monitoring |
