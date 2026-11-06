# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
User → SageMaker Runtime (SigV4/IAM) → Endpoint instance(s) ml.g5.xlarge (A10G GPU)
                                            │  :8080 Caddy shim  /ping → /v1/health/ready
                                            │                    /invocations → /v1/chat/completions
                                            └─ :8000 NIM (OpenAI-compatible API)
                                            ↑
                    Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (SageMaker-compatible NIM image)

Compared with the previous EKS version there is no VPC/NAT, cluster, DCGM exporter, Prometheus or HPA to run —
SageMaker publishes `GPUUtilization` to CloudWatch natively and scales the endpoint variant on it.

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform` and `docker` installed (build host must be able to build `linux/amd64` images; the NIM image is large, ~15 GB)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances` (default 3)
- ~$1.40/hr budget per `ml.g5.xlarge` instance (us-east-1 on-demand)

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit with your values
cd ..
./scripts/deploy.sh <your-ngc-api-key>
```

`deploy.sh` will:
1. Create the ECR repository (`terraform apply -target=aws_ecr_repository.nim`)
2. Build `container/` on top of the NIM image and push it to ECR (`scripts/build_and_push.sh`)
3. Apply the rest of the stack: SageMaker model, endpoint config, endpoint and autoscaling

First boot downloads weights and builds the TensorRT-LLM engine; the endpoint becomes `InService`
once `/ping` (NIM readiness) returns 200 — allow up to ~15–20 minutes.

## Test it

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

The request body is the standard OpenAI chat-completions payload. Streaming (`"stream": true`) works with
`invoke-endpoint-with-response-stream`.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Watch instances scale (target tracking alarms evaluate over several minutes, so run the test long enough):

```bash
watch -n 30 "aws sagemaker describe-endpoint --endpoint-name nim-demo --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'"
```

## Teardown

```bash
cd terraform && terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Security notes

- The endpoint has no public URL; callers need `sagemaker:InvokeEndpoint` IAM permission.
- `NGC_API_KEY` is passed to the container as a SageMaker model environment variable (Terraform variable is
  marked `sensitive`, but the value is stored in Terraform state and visible via `DescribeModel`). Use an
  encrypted remote state backend and restrict `sagemaker:DescribeModel` accordingly.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker hosting contract | `container/` | Maps `/ping` + `/invocations` on :8080 to NIM's API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy.gpu_util`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
