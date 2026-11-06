# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint that autoscales on GPU utilization.

## Architecture

```
User ─(SigV4 InvokeEndpoint)→ SageMaker endpoint → ml.g5.xlarge instance(s) (A10G GPU)
                                                     └ container: Caddy shim :8080 → NIM :8000
                                    ↑
              Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (NIM image + SageMaker shim, pushed to ECR)

### Why a shim?

SageMaker containers must serve `GET /ping` and `POST /invocations` on port 8080, while NIM serves an
OpenAI-compatible API on port 8000. `container/` wraps the NIM image with a tiny [Caddy](https://caddyserver.com/)
reverse proxy:

| SageMaker path | NIM path |
|----------------|----------|
| `GET /ping` | `GET /v1/health/ready` |
| `POST /invocations` | `POST /v1/chat/completions` |

SageMaker can only pull images from ECR, so the deploy script mirrors the NIM image from `nvcr.io` into ECR.

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` installed (Docker must be able to build `linux/amd64` images, ~20 GB free disk)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- Service quota **"ml.g5.xlarge for endpoint usage"** ≥ `max_instances` (default 3) in your region
- ~$1.41/hr per ml.g5.xlarge instance (us-east-1 on-demand)

## Deploy (~20-30 minutes)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # optional: edit with your values
NGC_API_KEY=<your-ngc-api-key> ./scripts/deploy.sh
```

The script:
1. creates the ECR repository (`terraform apply -target=aws_ecr_repository.nim`),
2. pulls the NIM image, builds the SageMaker image from `container/` and pushes it to ECR,
3. runs `terraform apply` to create the SageMaker model, endpoint and autoscaling policy.

The endpoint becomes `InService` once NIM has downloaded the weights and built its TensorRT-LLM engine
(`container_startup_timeout`, default 30 min).

### Test it

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

Container logs: `aws logs tail /aws/sagemaker/Endpoints/nim-demo --follow`

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 120
```

Watch instances scale:

```bash
watch -n 15 "aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'"
```

Note: target tracking creates CloudWatch alarms that need several minutes of sustained load (and a new
instance needs time to download the model) before capacity changes.

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Security notes

- The NGC API key is passed to the container as a SageMaker model environment variable. It is marked
  `sensitive` in Terraform, but it is still stored in Terraform state and visible to principals allowed to
  call `sagemaker:DescribeModel`. Protect your state backend and use a key scoped to NIM pulls.
- The endpoint is only reachable through the SigV4-authenticated SageMaker Runtime API (no public load balancer).
- The SageMaker execution role is limited to pulling from the NIM ECR repository and writing SageMaker logs/metrics.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `container/` | Adapts NIM's API to `/ping` + `/invocations` on :8080 |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU or request count |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
