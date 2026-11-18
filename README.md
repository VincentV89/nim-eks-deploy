# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> This project previously ran NIM on Amazon EKS. It now uses SageMaker managed hosting, so there is
> no VPC/EKS cluster, node groups, DCGM exporter, Prometheus or HPA to operate.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo-nim-llm"
                                       └─ ml.g5.xlarge instance(s) (A10G GPU)
                                            └─ Caddy :8080 (/ping, /invocations) → NIM :8000
                                       ↑
              Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Docker (wrap NIM for SageMaker → ECR) → Terraform (IAM, model, endpoint, autoscaling)

| EKS (before) | SageMaker (now) |
|---|---|
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint` (`terraform/main.tf`) |
| `k8s/nim-service.yaml` (LoadBalancer) | SageMaker Runtime `InvokeEndpoint` (IAM-authenticated, no public LB) |
| `k8s/nim-hpa.yaml` on DCGM `DCGM_FI_DEV_GPU_UTIL` | `aws_appautoscaling_policy` on `/aws/sagemaker/Endpoints` `GPUUtilization` |
| Readiness probe `/v1/health/ready` | SageMaker `/ping` → proxied to `/v1/health/ready` |
| NGC image pull secret | Image mirrored to ECR by `scripts/deploy.sh` |

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM, Application Auto Scaling
- `terraform`, `docker` installed (an x86_64 build host is recommended — the NIM image is ~10+ GB)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- `ml.g5.xlarge` endpoint-usage service quota ≥ `max_instances` in your region
- ~$1.41/hr budget per `ml.g5.xlarge` instance (us-east-1 on-demand)

## Deploy

```bash
# Optional: override defaults (instance type, min/max instances, GPU target)
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Creates ECR repo → builds & pushes the SageMaker-wrapped NIM image → creates the endpoint
./scripts/deploy.sh <your-ngc-api-key>
```

The first `terraform apply` waits until the endpoint is `InService` (TensorRT engine build and
weight download can take 10–20 minutes).

### Test it

`/invocations` accepts the same OpenAI chat-completions body that NIM serves on `/v1/chat/completions`:

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo-nim-llm \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
pip install boto3          # aiohttp is only needed for --url mode
python scripts/load_test.py --endpoint-name nim-demo-nim-llm --rps 20 --duration 600
```

Watch scaling:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker
aws sagemaker describe-endpoint --endpoint-name nim-demo-nim-llm \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

SageMaker publishes `GPUUtilization` at 1-minute granularity and target tracking needs several
datapoints, so scale-out takes a few minutes longer than the old HPA.

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `sagemaker/` | `/ping` + `/invocations` on :8080, mapped onto NIM's API |
| GPU-aware autoscaling | `terraform/main.tf` | Scales on real GPU utilization, not CPU or request count |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |

## Security notes

- The NGC API key is passed to the container as a SageMaker model environment variable (visible to
  principals with `sagemaker:DescribeModel`). It is marked `sensitive` in Terraform but is stored in
  Terraform state — use an encrypted remote backend for anything beyond a demo.
- The endpoint has no public network listener; callers need `sagemaker:InvokeEndpoint` IAM permission.
