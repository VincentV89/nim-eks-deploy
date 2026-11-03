# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker endpoint → ml.g5.xlarge instance(s) (A10G GPU)
                                        └─ container: Caddy :8080 → NIM :8000
                       ↑
   Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, Secrets Manager, SageMaker, autoscaling) → Docker (NIM + SageMaker shim)

SageMaker requires hosting containers to serve `GET /ping` and `POST /invocations` on port 8080.
The image in [`sagemaker/`](sagemaker/) wraps the stock NIM image with a small Caddy reverse proxy:

| SageMaker route | NIM route |
|-----------------|-----------|
| `GET /ping` | `GET /v1/health/ready` |
| `POST /invocations` | `POST /v1/chat/completions` (OpenAI-compatible, streaming supported) |

The NGC API key is stored in Secrets Manager (written by `deploy.sh`, never in Terraform state) and read by the
container at startup so NIM can download the model weights.

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` installed (image is built for `linux/amd64`)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances`
- ~$1.50/hr per `ml.g5.xlarge` endpoint instance (on-demand, us-east-1)

## Deploy

```bash
# Optional: customise region / instance type / scaling bounds
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Build + push the image, store the NGC key, create the endpoint
NGC_API_KEY=<your-ngc-api-key> ./scripts/deploy.sh
```

The endpoint takes ~10–20 minutes to become `InService` on first deploy (weight download + engine load).
Container logs are in CloudWatch under `/aws/sagemaker/Endpoints/nim-demo`.

## Test it

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 120
```

Watch instances scale:

```bash
aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
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
| SageMaker container contract | `sagemaker/Caddyfile` | Maps `/ping` + `/invocations` on :8080 to NIM |
| GPU-aware autoscaling | `aws_appautoscaling_policy` in `terraform/main.tf` | Scales on real GPU utilization, not invocations/CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
