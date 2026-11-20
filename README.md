# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker InvokeEndpoint → ml.g5.xlarge instance(s) (A10G GPU)
                                               └─ Caddy :8080 (/ping, /invocations) → NIM :8000
                         ↑
   Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (mirror NIM from nvcr.io into ECR with a SageMaker shim)

SageMaker containers must listen on port 8080 and implement `GET /ping` and `POST /invocations`.
`container/` wraps the stock NIM image with a small Caddy reverse proxy:

| SageMaker route | NIM route |
|-----------------|-----------|
| `GET /ping` | `GET /v1/health/ready` |
| `POST /invocations` | `POST /v1/chat/completions` (OpenAI-compatible body) |

## Prerequisites

- AWS CLI configured with permissions for ECR, IAM, SageMaker, Application Auto Scaling
- `terraform`, `docker` installed (or `mise install` for terraform/shellcheck)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances`
- ~$1.41/hr per ml.g5.xlarge endpoint instance (us-east-1 on-demand)

## Deploy (~20 minutes)

```bash
# Optional: cp terraform/terraform.tfvars.example terraform/terraform.tfvars and edit
./scripts/deploy.sh <your-ngc-api-key>
```

`deploy.sh` creates the ECR repo, pulls the NIM image from `nvcr.io`, builds the SageMaker
wrapper, pushes it to ECR, then applies the rest of the Terraform (model, endpoint config,
endpoint, autoscaling). First boot downloads weights and loads the TensorRT-LLM engine, so the
endpoint can take 10–20 minutes to become `InService`.

## Test it

```bash
pip install boto3
python scripts/invoke.py --endpoint nim-demo --prompt "Hello"
```

Or with the AWS CLI:

```bash
aws sagemaker-runtime invoke-endpoint --endpoint-name nim-demo \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
python scripts/load_test.py --endpoint nim-demo --rps 20 --duration 600
```

Watch scaling:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker
aws sagemaker describe-endpoint --endpoint-name nim-demo --query 'ProductionVariants[0].CurrentInstanceCount'
```

Note: target tracking uses CloudWatch alarms (1-minute metrics), so scale-out reacts in minutes,
and each new instance pays the NIM cold start.

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. Local static checks: `mise run build` (terraform validate) and `mise run lint` (fmt, shellcheck, py_compile).

## Migration from EKS

| EKS (before) | SageMaker (now) |
|--------------|-----------------|
| VPC + NAT + EKS cluster + node groups | Managed endpoint (no VPC/cluster to run) |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint_configuration` |
| `k8s/nim-service.yaml` (public LoadBalancer) | `InvokeEndpoint` (IAM/SigV4-authenticated) |
| Readiness probe `/v1/health/ready` | `/ping` → `/v1/health/ready` via Caddy shim |
| `k8s/nim-hpa.yaml` + DCGM + Prometheus + Adapter | Application Auto Scaling on `GPUUtilization` |
| NGC image pull secret | Image mirrored into ECR |

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not invocations |
| SageMaker container contract | `container/` | Adapts NIM's OpenAI API to `/ping` + `/invocations` |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
